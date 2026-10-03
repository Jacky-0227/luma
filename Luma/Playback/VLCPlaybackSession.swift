import Foundation
import OSLog
import UIKit

/// Only value snapshots cross the Objective-C callback boundary. No URL, error
/// text, credentials, SDK object, or UIKit view is carried in an event.
enum VLCPlaybackEvent: Sendable {
    case opening
    case buffering
    case videoPlaying
    case firstFrame
    case routeUnavailable
    case routeConflict
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

    private var driver: VLCNativeDriver?
    // Own the drawable on MainActor until the native input has fully stopped.
    private var surface: UIView?
    private var hasVideo = false
    private var isRetiring = false
    private var isDisposing = false
    private var captureState: CaptureState = .idle
    private var capture: CaptureDestination?
    private var recordingWorkspace: CaptureDestination?
    private var abandonedCaptures: [CaptureDestination] = []
    private var captureTimeout: Task<Void, Never>?
    private struct PreviewCapture {
        let fileURL: URL
        let completion: @MainActor @Sendable (Bool) -> Void
    }
    private enum DeferredCapture { case snapshot, recording }
    private var previewCapture: PreviewCapture?
    private var previewSubmitted = false
    private var previewTimeout: Task<Void, Never>?
    private var deferredCapture: DeferredCapture?
    private var previewCleanup: [@MainActor @Sendable () -> Void] = []
    private var recordingLimit: Task<Void, Never>?
    private var retirementCompletions: [@MainActor @Sendable () -> Void] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var retirementRetainer: VLCPlaybackSession?
    private var retirementFinished = false

    init(url: URL, useTCP: Bool, profile: PlaybackProfile = .interactive) {
        driver = VLCNativeDriver(url: url, useTCP: useTCP, profile: profile) { [weak self] event in
            self?.handle(event)
        }
    }

    func start(on view: UIView, muted: Bool, aspectFill: Bool) {
        guard !isRetiring else { return }
        surface = view
        driver?.start(on: view, muted: muted, aspectFill: aspectFill)
    }

    func setMuted(_ muted: Bool) {
        guard !isRetiring else { return }
        driver?.setMuted(muted)
    }

    /// A private home-card preview shares the native snapshot lane, but never
    /// creates a MediaLibrary item or reports a user capture notification.
    func capturePreview(at url: URL, cleanup: (@MainActor @Sendable () -> Void)? = nil,
                        completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !isRetiring, hasVideo, previewCapture == nil, url.isFileURL else {
            completion(false)
            return
        }
        if let cleanup { previewCleanup.append(cleanup) }
        previewCapture = PreviewCapture(fileURL: url.standardizedFileURL, completion: completion)
        beginPreviewIfReady()
    }

    private func beginPreviewIfReady() {
        guard !isRetiring, hasVideo, capture == nil, deferredCapture == nil,
              !previewSubmitted, let previewCapture else { return }
        previewSubmitted = true
        previewTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finishPreview(success: false)
        }
        driver?.captureSnapshot(at: previewCapture.fileURL.path) { [weak self] submitted in
            guard let self, self.previewCapture?.fileURL == previewCapture.fileURL else { return }
            if !submitted { self.finishPreview(success: false) }
        }
    }

    private func finishPreview(success: Bool) {
        guard let previewCapture else { return }
        self.previewCapture = nil
        previewSubmitted = false
        previewTimeout?.cancel()
        previewTimeout = nil
        previewCapture.completion(success)
        let deferred = deferredCapture
        deferredCapture = nil
        guard !isRetiring else {
            if deferred != nil { setCaptureState(.idle) }
            return
        }
        // Keep libvlc's snapshot filename from being overwritten by a manual
        // snapshot. Explicit user actions take the next available capture slot.
        switch deferred {
        case .snapshot: captureSnapshot()
        case .recording: toggleRecording()
        case nil: break
        }
    }

    func captureSnapshot() {
        guard !isRetiring, capture == nil, hasVideo else { return }
        if previewSubmitted {
            guard deferredCapture == nil else { return }
            deferredCapture = .snapshot
            setCaptureState(.savingSnapshot)
            return
        }
        do {
            let destination = try MediaLibrary.shared.prepare(.snapshot)
            capture = destination
            setCaptureState(.savingSnapshot)
            armCaptureTimeout(seconds: 8)
            driver?.captureSnapshot(at: destination.snapshotURL.path) { [weak self] submitted in
                guard let self, self.capture?.id == destination.id else { return }
                if !submitted { self.failCapture() }
            }
        } catch {
            setCaptureState(.idle)
            onCaptureEvent?(.failed(MediaLibraryError.saveFailed.localizedDescription))
            beginPreviewIfReady()
        }
    }

    func toggleRecording() {
        guard !isRetiring else { return }
        if capture?.kind == .recording {
            finishRecording()
            return
        }
        guard capture == nil, hasVideo else { return }
        if previewSubmitted {
            guard deferredCapture == nil else { return }
            deferredCapture = .recording
            setCaptureState(.startingRecording)
            return
        }
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
            driver?.startRecording(at: recordingWorkspace.directory.path) { [weak self] submitted in
                guard let self, self.capture?.id == destination.id else { return }
                if !submitted { self.failCapture() }
            }
        } catch {
            setCaptureState(.idle)
            onCaptureEvent?(.failed(MediaLibraryError.saveFailed.localizedDescription))
            beginPreviewIfReady()
        }
    }

    private func finishRecording() {
        guard capture?.kind == .recording, captureState != .finishingRecording else { return }
        recordingLimit?.cancel()
        recordingLimit = nil
        setCaptureState(.finishingRecording)
        driver?.stopRecording()
        armCaptureTimeout(seconds: 15)
    }

    private func handle(_ event: VLCPlaybackEvent) {
        switch event {
        case .videoPlaying, .firstFrame:
            hasVideo = true
            if !isRetiring { onEvent?(event) }
        case .snapshotSaved(let path):
            let matchesPreview = previewCapture.map { URL(fileURLWithPath: path).standardizedFileURL == $0.fileURL } ?? false
            let matchesManual = capture.map { URL(fileURLWithPath: path).standardizedFileURL == $0.snapshotURL.standardizedFileURL } ?? false
            Logger(subsystem: "app.luma.viewer", category: "Capture")
                .notice("snapshot_callback preview=\(matchesPreview) manual=\(matchesManual)")
            if let previewCapture, previewSubmitted,
               URL(fileURLWithPath: path).standardizedFileURL == previewCapture.fileURL {
                finishPreview(success: true)
                return
            }
            guard let capture, capture.kind == .snapshot,
                  URL(fileURLWithPath: path).standardizedFileURL == capture.snapshotURL.standardizedFileURL else { return }
            finishCapture(path: path)
        case .recordingStarted:
            guard capture?.kind == .recording else { return }
            if isRetiring || captureState == .finishingRecording {
                driver?.stopRecording()
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
            else { beginPreviewIfReady() }
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
        if wasRecording { driver?.stopRecording() }
        clearCapture()
        onCaptureEvent?(.failed(String(localized: "Capture failed. The stream may have disconnected or this format may not support recording.")))
        if isRetiring {
            disposePlayer()
        } else if wasRecording {
            // Force a clean decoder stop if recording could not be finalized.
            // A failed capture is never silently left recording in the background.
            onEvent?(.failed)
        } else {
            beginPreviewIfReady()
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
    func pollVideoProgress() {
        guard !isRetiring else { return }
        driver?.pollVideoProgress()
    }

    func setAspectFill(_ fill: Bool, bounds: CGRect) {
        guard !isRetiring else { return }
        driver?.setAspectFill(fill, bounds: bounds)
    }

    /// Capture completion remains UI-owned. Native input shutdown and any
    /// SDK locks run on the driver queue; the view stays alive until completion.
    func retire(completion: (@MainActor @Sendable () -> Void)? = nil) {
        if retirementFinished { completion?(); return }
        if let completion { retirementCompletions.append(completion) }
        guard !isRetiring else { return }
        isRetiring = true
        retirementRetainer = self
        finishPreview(success: false)
        onEvent = nil
        driver?.setMuted(true)
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
        guard let driver else { finishRetirement(); return }
        onCaptureEvent = nil
        driver.retire { [self] completed in
            guard completed else { return }
            self.driver = nil
            surface = nil
            finishRetirement()
        }
    }

    private func finishRetirement() {
        retirementFinished = true
        // A timed-out SDK snapshot can finish writing late. Its owner deletes
        // the per-request staging directory on failure and once more after the
        // native input is fully stopped, so it cannot leave orphaned previews.
        for cleanup in previewCleanup { cleanup() }
        previewCleanup = []
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
