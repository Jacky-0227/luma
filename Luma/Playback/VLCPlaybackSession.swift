import Foundation
import UIKit
@preconcurrency import MobileVLCKit

/// Only value snapshots cross the Objective-C callback boundary. No URL, error
/// text, credentials, SDK object, or UIKit view is carried in an event.
enum VLCPlaybackEvent: Sendable {
    case opening
    case buffering
    case videoPlaying
    case failed
    case ended
    case snapshotSaved(String)
    case recordingStarted
    case recordingStopped(String)
}

enum CaptureState: Equatable, Sendable {
    case idle, savingSnapshot, startingRecording, recording, finishingRecording
}

enum CaptureEvent: Sendable {
    case state(CaptureState)
    case recordingStarted(Date)
    case saved(CaptureKind)
    case failed(String)
}

@MainActor
final class VLCPlaybackSession {
    let id = UUID()
    var onEvent: (@MainActor @Sendable (VLCPlaybackEvent) -> Void)?
    var onCaptureEvent: (@MainActor @Sendable (CaptureEvent) -> Void)?

    private var player: VLCMediaPlayer?
    private var bridge: VLCEventBridge?
    private weak var surface: UIView?
    private var lastCropGeometry: String?
    private var lastDecodedVideo: Int32 = 0
    private var lastDisplayedPictures: Int32 = 0
    private var isRetiring = false
    private var isDisposing = false
    private var captureState: CaptureState = .idle
    private var capture: CaptureDestination?
    private var recordingWorkspace: CaptureDestination?
    private var abandonedCaptures: [CaptureDestination] = []
    private var captureTimeout: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var retirementCompletions: [@MainActor @Sendable () -> Void] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var retirementRetainer: VLCPlaybackSession?
    private var retirementFinished = false

    init(url: URL, useTCP: Bool) {
        // MobileVLCKit 3.7.3 defaults to this configuration. Set it explicitly
        // before registering any events: cached SDK state and all our SDK/UI
        // mutations remain on the main queue. The application never changes it.
        VLCLibrary.sharedEventsConfiguration = VLCEventsLegacyConfiguration()
        let mediaPlayer = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show"])
        mediaPlayer.libraryInstance.loggers = nil
        let media = VLCMedia(url: url)
        media.metaData.title = "Luma"
        media.metaData.url = nil
        media.addOption(":network-caching=500")
        if useTCP { media.addOption(":rtsp-tcp") }
        mediaPlayer.media = media
        player = mediaPlayer

        let callback = VLCEventBridge { [weak self] event in
            self?.handle(event)
        }
        bridge = callback
        mediaPlayer.delegate = callback
    }

    func start(on view: UIView, muted: Bool, aspectFill: Bool) {
        guard let player, !isRetiring else { return }
        surface = view
        player.drawable = view
        setMuted(muted)
        setAspectFill(aspectFill, bounds: view.bounds)
        player.play()
    }

    func setMuted(_ muted: Bool) {
        guard let player, !isRetiring else { return }
        // VLCKit exposes the weak audio controller as optional. It may not
        // exist before playback; CameraPlayer reapplies the requested mute
        // state when the first real video-playing event arrives.
        player.audio?.isMuted = muted
    }

    func captureSnapshot() {
        guard !isRetiring, capture == nil, let player, player.hasVideoOut else { return }
        do {
            let destination = try MediaLibrary.shared.prepare(.snapshot)
            capture = destination
            setCaptureState(.savingSnapshot)
            armCaptureTimeout(seconds: 8)
            if !LumaRequestSnapshot(player, destination.snapshotURL.path) {
                failCapture()
            }
        } catch {
            onCaptureEvent?(.failed(MediaLibraryError.saveFailed.localizedDescription))
        }
    }

    func toggleRecording() {
        guard !isRetiring else { return }
        if capture?.kind == .recording {
            finishRecording()
            return
        }
        guard capture == nil, let player, player.hasVideoOut else { return }
        do {
            // libvlc's input inherits input-record-path once and caches it.
            // Every recording in this session must use that same directory.
            if recordingWorkspace == nil {
                recordingWorkspace = try MediaLibrary.shared.prepare(.recording)
            }
            guard let recordingWorkspace else { throw MediaLibraryError.saveFailed }
            let destination = try MediaLibrary.shared.prepare(.recording)
            capture = destination
            setCaptureState(.startingRecording)
            armCaptureTimeout(seconds: 10)
            // 3.7.3 directly casts libvlc's 0(success)/-1(error) to BOOL.
            // Do not interpret this broken BOOL contract as proof of success.
            // Only the started/stopped delegates and validated file confirm it.
            _ = player.startRecording(atPath: recordingWorkspace.directory.path)
        } catch {
            onCaptureEvent?(.failed(MediaLibraryError.saveFailed.localizedDescription))
        }
    }

    private func finishRecording() {
        guard capture?.kind == .recording, captureState != .finishingRecording else { return }
        recordingLimit?.cancel()
        recordingLimit = nil
        setCaptureState(.finishingRecording)
        _ = player?.stopRecording()
        armCaptureTimeout(seconds: 15)
    }

    private func handle(_ event: VLCPlaybackEvent) {
        switch event {
        case .snapshotSaved(let path):
            guard let capture, capture.kind == .snapshot,
                  URL(fileURLWithPath: path).standardizedFileURL == capture.snapshotURL.standardizedFileURL else { return }
            finishCapture(path: path)
        case .recordingStarted:
            guard capture?.kind == .recording else { return }
            if isRetiring || captureState == .finishingRecording {
                _ = player?.stopRecording()
                return
            }
            captureTimeout?.cancel()
            captureTimeout = nil
            setCaptureState(.recording)
            onCaptureEvent?(.recordingStarted(Date()))
            recordingLimit?.cancel()
            recordingLimit = Task { @MainActor [weak self] in
                guard self?.captureState == .recording else { return }
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.finishRecording()
            }
        case .recordingStopped(let path):
            guard capture?.kind == .recording else { return }
            if let recordingWorkspace, !path.isEmpty,
               !MediaLibrary.isDirectChild(URL(fileURLWithPath: path), of: recordingWorkspace.directory) { return }
            finishCapture(path: path)
        default:
            if !isRetiring { onEvent?(event) }
        }
    }

    private func finishCapture(path: String) {
        guard let capture, !path.isEmpty else { failCapture(); return }
        do {
            var fileURL = URL(fileURLWithPath: path)
            if capture.kind == .recording {
                guard let recordingWorkspace else { throw MediaLibraryError.invalidCapture }
                fileURL = try MediaLibrary.shared.stageRecording(fileURL: fileURL, from: recordingWorkspace, into: capture)
            }
            try MediaLibrary.shared.finish(capture, fileURL: fileURL)
            clearCapture()
            onCaptureEvent?(.saved(capture.kind))
            if isRetiring { disposePlayer() }
        } catch {
            failCapture()
        }
    }

    private func clearCapture() {
        captureTimeout?.cancel()
        captureTimeout = nil
        recordingLimit?.cancel()
        recordingLimit = nil
        capture = nil
        setCaptureState(.idle)
    }

    private func failCapture() {
        let wasRecording = capture?.kind == .recording
        if let capture { abandonedCaptures.append(capture) }
        if wasRecording { _ = player?.stopRecording() }
        clearCapture()
        onCaptureEvent?(.failed(String(localized: "Capture failed. The stream may have disconnected or this format may not support recording.")))
        if isRetiring {
            disposePlayer()
        } else if wasRecording {
            // Force a clean decoder stop if recording could not be finalized.
            // A failed capture is never silently left recording in the background.
            onEvent?(.failed)
        }
    }

    private func setCaptureState(_ state: CaptureState) {
        captureState = state
        onCaptureEvent?(.state(state))
    }

    private func armCaptureTimeout(seconds: Int) {
        captureTimeout?.cancel()
        captureTimeout = Task { @MainActor [weak self] in
            guard self?.capture != nil else { return }
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.failCapture()
        }
    }

    /// Live RTSP streams need not report a useful timeline. Frame statistics
    /// are a second liveness signal and advance even when the scene is static.
    func videoMadeProgress() -> Bool {
        guard let player, !isRetiring, player.hasVideoOut,
              let media = player.media else { return false }
        let statistics = media.statistics
        let progressed = statistics.decodedVideo != lastDecodedVideo
            || statistics.displayedPictures != lastDisplayedPictures
        lastDecodedVideo = statistics.decodedVideo
        lastDisplayedPictures = statistics.displayedPictures
        return progressed
    }

    func setAspectFill(_ fill: Bool, bounds: CGRect) {
        guard let player, !isRetiring, bounds.width > 0, bounds.height > 0 else { return }
        let geometry = fill ? "\(Int(bounds.width.rounded())):\(Int(bounds.height.rounded()))" : nil
        guard geometry != lastCropGeometry else { return }
        lastCropGeometry = geometry
        player.videoAspectRatio = nil
        player.scaleFactor = 0
        if let geometry {
            // libvlc copies the geometry in its setter; the pointer is valid
            // for this call only. Cropping preserves the original video ratio.
            geometry.withCString { pointer in
                player.videoCropGeometry = UnsafeMutablePointer(mutating: pointer)
            }
        } else {
            player.videoCropGeometry = nil
        }
    }

    /// SDK stop is asynchronous, but final player release can join its decoder
    /// worker. Invalidate callbacks on the UI actor, then exclusively transfer
    /// final destruction to a serial queue. Keep the view alive until that ends.
    func retire(completion: (@MainActor @Sendable () -> Void)? = nil) {
        if retirementFinished { completion?(); return }
        if let completion { retirementCompletions.append(completion) }
        guard !isRetiring else { return }
        isRetiring = true
        retirementRetainer = self
        onEvent = nil
        player?.audio?.isMuted = true
        if capture != nil {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish local capture") { [weak self] in
                Task { @MainActor in self?.failCapture() }
            }
            if capture?.kind == .recording { finishRecording() }
        } else {
            disposePlayer()
        }
    }

    private func disposePlayer() {
        guard !isDisposing else { return }
        isDisposing = true
        guard let player else { finishRetirement(); return }
        onCaptureEvent = nil
        player.delegate = nil
        bridge = nil
        player.stop()
        let retainedSurface = surface
        surface = nil
        player.drawable = nil
        player.media = nil

        let disposal = VLCDisposalBox(player: player)
        self.player = nil

        // Enqueue on the next main turn so this method's temporary strong
        // references have left the stack before background destruction begins.
        DispatchQueue.main.async {
            VLCDisposalBox.queue.async {
                disposal.releasePlayer()
                DispatchQueue.main.async {
                    // UIKit lifetime ends on the main queue, after the decoder
                    // stopped using its old drawable. Starting a replacement
                    // stream is safe only after this callback.
                    withExtendedLifetime(retainedSurface) {
                        self.finishRetirement()
                    }
                }
            }
        }
    }

    private func finishRetirement() {
        retirementFinished = true
        // The input can no longer write to its cached recording path. A
        // successful capture deletes only its own archive staging directory.
        for destination in abandonedCaptures { MediaLibrary.shared.discard(destination) }
        abandonedCaptures = []
        if let recordingWorkspace { MediaLibrary.shared.discard(recordingWorkspace) }
        recordingWorkspace = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        let completions = retirementCompletions
        retirementCompletions = []
        for completion in completions { completion() }
        retirementRetainer = nil
    }
}

/// MobileVLCKit is Objective-C and does not express isolation. The bridge itself
/// is immutable. It reads SDK snapshots in VLC's explicitly configured main
/// callback queue, then sends only Sendable values to its MainActor recipient.
private final class VLCEventBridge: NSObject, VLCMediaPlayerDelegate {
    private let onEvent: @MainActor @Sendable (VLCPlaybackEvent) -> Void

    init(onEvent: @escaping @MainActor @Sendable (VLCPlaybackEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        let event: VLCPlaybackEvent
        switch player.state {
        case .opening:
            event = .opening
        case .buffering:
            event = .buffering
        case .playing:
            // A playing event can precede the video output, or be audio-only.
            // A time event will confirm the video once the renderer is ready.
            event = player.hasVideoOut ? .videoPlaying : .opening
        case .error:
            event = .failed
        case .stopped, .ended, .paused:
            event = .ended
        default:
            return
        }
        send(event)
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer,
              player.isPlaying, player.hasVideoOut else { return }
        send(.videoPlaying)
    }

    func mediaPlayerSnapshot(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer,
              let path = player.snapshots?.last as? String else { return }
        send(.snapshotSaved(path))
    }

    func mediaPlayerStartedRecording(_ player: VLCMediaPlayer) {
        send(.recordingStarted)
    }

    func mediaPlayer(_ player: VLCMediaPlayer, recordingStoppedAtPath path: String) {
        send(.recordingStopped(path))
    }

    private func send(_ event: VLCPlaybackEvent) {
        let recipient = onEvent
        DispatchQueue.main.async {
            recipient(event)
        }
    }
}

/// Safety invariant: constructed on MainActor, published exactly once, then its
/// player is accessed ONLY by `queue`. The app drops all other references and
/// invalidates its delegate before publication. This narrowly scoped unchecked
/// transfer avoids asserting that VLCMediaPlayer itself is generally Sendable.
/// Remove the box when the SDK exposes an asynchronous completion-based dispose.
private final class VLCDisposalBox: @unchecked Sendable {
    static let queue = DispatchQueue(label: "app.luma.vlc-disposal", qos: .utility)
    private var player: VLCMediaPlayer?

    init(player: VLCMediaPlayer) {
        self.player = player
    }

    func releasePlayer() {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        player = nil
    }
}
