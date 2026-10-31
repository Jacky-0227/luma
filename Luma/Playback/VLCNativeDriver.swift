import Foundation
import OSLog
import Synchronization
import UIKit
@preconcurrency import MobileVLCKit

/// A UIView remains owned by the MainActor session until shutdown completes.
/// The SDK queue may only pass this reference to VLCKit's opaque drawable
/// setter; it must never read layout, create views or call UIKit on this queue.
private final class VLCVideoAttachment: @unchecked Sendable {
    let view: UIView
    @MainActor init(_ view: UIView) { self.view = view }
}

/// Carries a retiring player to the blocking queue for the native stop only.
/// After `retire` sets the cancellation bit, no other application code issues
/// commands to it; the SDK queue resumes ownership once stop returns.
private final class VLCRetiringPlayer: @unchecked Sendable {
    let player: VLCMediaPlayer
    init(_ player: VLCMediaPlayer) { self.player = player }
}

private enum VLCSDKQueue {
    static let queue = DispatchQueue(label: "app.luma.vlc-sdk", qos: .userInitiated)
    /// Native calls that can block for seconds (input shutdown, route lookup).
    /// They never touch VLCKit cached properties, so they need not hold the
    /// shared SDK queue, where they would delay every other camera.
    static let blocking = DispatchQueue(label: "app.luma.vlc-blocking", qos: .userInitiated, attributes: .concurrent)

    // VLCMedia(url:) always uses VLCLibrary.sharedLibrary. Use the same shared
    // library for players instead of allocating another library per connection.
    // Registration is volatile (not persisted) and precedes its first creation.
    static let configure: Void = {
        dispatchPrecondition(condition: .notOnQueue(.main))
        UserDefaults.standard.register(defaults: ["VLCParams": [
            "--no-color", "--no-osd", "--no-video-title-show", "--no-snapshot-preview",
            "--http-reconnect", "--text-renderer=freetype", "--avi-index=3",
            "--audio-resampler=soxr", "--quiet"
        ]])
    }()
}

/// Only the SDK queue may touch this policy or the native data symbol. Native
/// RTSP workers read that symbol concurrently, so a lease forbids writes until
/// every old worker has completed synchronous shutdown (including socket Close).
private final class VLCInterfaceLeases: @unchecked Sendable {
    static let shared = VLCInterfaceLeases()
    private var state = RTSPInterfaceLeaseState()

    func acquire(owner: UUID, address: UInt32) -> Bool {
        dispatchPrecondition(condition: .onQueue(VLCSDKQueue.queue))
        switch state.acquire(owner: owner, address: address) {
        case .configure:
            LumaSetRTSPReceivingInterface(address)
            return true
        case .reuse:
            return true
        case .conflict, .invalid:
            return false
        }
    }

    func release(owner: UUID) {
        dispatchPrecondition(condition: .onQueue(VLCSDKQueue.queue))
        state.release(owner: owner)
        // Leave the native value untouched. A subsequent first lease replaces
        // it before starting any input, including after a Wi-Fi/VPN change.
    }
}

private final class VLCQueueEventConfiguration: NSObject, VLCEventsConfiguring {
    func dispatchQueue() -> DispatchQueue? { VLCSDKQueue.queue }
    func isAsync() -> Bool { true }
}

@MainActor
private enum VLCEventPolicy {
    static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        // VLCKit also updates cached _media/_state in its event handlers.
        // Put those handlers on the same serial queue as commands; merely
        // moving setters off-main with legacy events would create a data race.
        VLCLibrary.sharedEventsConfiguration = VLCQueueEventConfiguration()
    }
}

/// Safety invariant: every application access to player/media and all native
/// commands and SDK cached-property updates occur on `queue`, except the two
/// blocking calls on `VLCSDKQueue.blocking`: route lookup (no SDK object) and
/// the final native stop of a cancelled player (see `retire`). Delegate
/// callbacks read cached state there and send only values to MainActor. The
/// cancellation bit alone is shared and protected by Mutex; no queue waits
/// synchronously for MainActor.
/// Replace this compatibility boundary when VLCKit provides Swift isolation and
/// completion-based shutdown. Do not make VLCMediaPlayer generally Sendable.
final class VLCNativeDriver: @unchecked Sendable {
    private static let captureLog = Logger(subsystem: "app.luma.viewer", category: "Capture")
    private let queue = VLCSDKQueue.queue
    private let cancelled = Mutex(false)
    private let onEvent: @MainActor @Sendable (VLCPlaybackEvent) -> Void
    private let rtspHost: String?
    private let rtspPort: UInt16
    private let leaseID = UUID()
    private var ownsInterfaceLease = false
    private var player: VLCMediaPlayer?
    private var media: VLCMedia?
    private var bridge: VLCEventBridge?
    private var cropGeometry: String?
    private var decodedVideo: Int32 = 0
    private var displayedPictures: Int32 = 0
    private var firstFrameProbe: DispatchSourceTimer?
    private var firstFrameReported = false

    @MainActor
    init(url: URL, useTCP: Bool, profile: PlaybackProfile, onEvent: @escaping @MainActor @Sendable (VLCPlaybackEvent) -> Void) {
        VLCEventPolicy.install()
        self.onEvent = onEvent
        rtspHost = url.scheme?.lowercased() == "rtsp" ? url.host : nil
        rtspPort = UInt16(clamping: url.port ?? 554)
        queue.async { [self] in
            guard !isCancelled else { return }
            _ = VLCSDKQueue.configure
            guard !isCancelled else { return }
            let nextPlayer = VLCMediaPlayer()
            nextPlayer.libraryInstance.loggers = nil
            let nextMedia = VLCMedia(url: url)
            nextMedia.metaData.title = "Luma"
            nextMedia.metaData.url = nil
            if url.scheme?.lowercased() == "rtsp" {
                for option in profile.mediaOptions { nextMedia.addOption(option) }
            }
            if useTCP { nextMedia.addOption(":rtsp-tcp") }
            let nextBridge = VLCEventBridge { [weak self] event in self?.enqueue(event) }
            player = nextPlayer
            media = nextMedia
            bridge = nextBridge
            nextPlayer.delegate = nextBridge
            nextPlayer.media = nextMedia
        }
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    @MainActor
    func start(on view: UIView, muted: Bool, aspectFill: Bool) {
        let attachment = VLCVideoAttachment(view)
        let bounds = view.bounds
        guard let rtspHost else {
            queue.async { [self] in begin(attachment, bounds: bounds, muted: muted, aspectFill: aspectFill, routeAddress: nil) }
            return
        }
        // Name resolution can block for seconds on an unreachable host.
        let port = rtspPort
        VLCSDKQueue.blocking.async { [self] in
            guard !isCancelled else { return }
            var address: UInt32 = 0
            let resolved = LumaRTSPLocalIPv4(rtspHost, port, &address)
            queue.async { [self] in
                guard resolved else {
                    if !isCancelled { emit(.routeUnavailable) }
                    return
                }
                begin(attachment, bounds: bounds, muted: muted, aspectFill: aspectFill, routeAddress: address)
            }
        }
    }

    private func begin(_ attachment: VLCVideoAttachment, bounds: CGRect, muted: Bool, aspectFill: Bool, routeAddress: UInt32?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isCancelled, let player else { return }
        if let address = routeAddress, !ownsInterfaceLease {
            guard VLCInterfaceLeases.shared.acquire(owner: leaseID, address: address) else {
                emit(.routeConflict)
                return
            }
            ownsInterfaceLease = true
        }
        player.drawable = attachment.view
        player.audio?.isMuted = muted
        applyAspectFill(aspectFill, bounds: bounds, player: player)
        guard !isCancelled else { return }
        player.play()
        startFirstFrameProbe()
    }

    func setMuted(_ muted: Bool) {
        queue.async { [self] in
            guard !isCancelled else { return }
            player?.audio?.isMuted = muted
        }
    }

    func setAspectFill(_ fill: Bool, bounds: CGRect) {
        queue.async { [self] in
            guard !isCancelled, let player else { return }
            applyAspectFill(fill, bounds: bounds, player: player)
        }
    }

    private func applyAspectFill(_ fill: Bool, bounds: CGRect, player: VLCMediaPlayer) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let geometry = fill ? "\(Int(bounds.width.rounded())):\(Int(bounds.height.rounded()))" : nil
        guard geometry != cropGeometry else { return }
        cropGeometry = geometry
        player.videoAspectRatio = nil
        player.scaleFactor = 0
        if let geometry {
            geometry.withCString { player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) }
        } else {
            player.videoCropGeometry = nil
        }
    }

    func pollVideoProgress() {
        queue.async { [self] in
            guard !isCancelled, let player, player.hasVideoOut, let media else { return }
            let stats = media.statistics
            let progressed = stats.decodedVideo != decodedVideo || stats.displayedPictures != displayedPictures
            decodedVideo = stats.decodedVideo
            displayedPictures = stats.displayedPictures
            reportFirstFrameIfReady(statsDecoded: stats.decodedVideo, statsDisplayed: stats.displayedPictures)
            if progressed { emit(.videoPlaying) }
        }
    }

    /// libvlc copies the next picture the vout *displays* and silently gives
    /// up after 500 ms. A live stream reports decoded frames while it is still
    /// pre-rolling its PTS delay, so a single request right after the first
    /// frame can be lost. The native call is synchronous and leaves no pending
    /// request when it fails, so retry until the file exists or time runs out.
    func captureSnapshot(at path: String, submitted: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            requestSnapshot(at: path, attempts: 0, deadline: .now() + Self.snapshotWindow,
                            nextBlindAttempt: .now(), submitted: submitted)
        }
    }

    /// Below the session's 8 s capture timeout.
    private static let snapshotWindow: DispatchTimeInterval = .seconds(6)

    private func requestSnapshot(at path: String, attempts: Int, deadline: DispatchTime, nextBlindAttempt: DispatchTime,
                                 submitted: @escaping @MainActor @Sendable (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isCancelled, let player, let media else {
            DispatchQueue.main.async { submitted(false) }
            return
        }
        let stats = media.statistics
        var attempts = attempts
        var nextBlindAttempt = nextBlindAttempt
        // Displayed-picture statistics can lag the vout, so also try once a
        // second without them instead of waiting on the counter forever.
        if stats.displayedPictures > 0 || DispatchTime.now() >= nextBlindAttempt {
            attempts += 1
            nextBlindAttempt = .now() + .seconds(1)
            if LumaRequestSnapshot(player, path), Self.fileHasContent(atPath: path) {
                Self.captureLog.notice("snapshot_written attempts=\(attempts) decoded=\(stats.decodedVideo) displayed=\(stats.displayedPictures)")
                DispatchQueue.main.async { submitted(true) }
                return
            }
        }
        guard DispatchTime.now() < deadline else {
            Self.captureLog.notice("snapshot_unavailable attempts=\(attempts) decoded=\(stats.decodedVideo) displayed=\(stats.displayedPictures)")
            DispatchQueue.main.async { submitted(false) }
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self, attempts, nextBlindAttempt] in
            requestSnapshot(at: path, attempts: attempts, deadline: deadline,
                            nextBlindAttempt: nextBlindAttempt, submitted: submitted)
        }
    }

    private static func fileHasContent(atPath path: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }

    func startRecording(at path: String, submitted: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard !isCancelled, let player, player.hasVideoOut else {
                DispatchQueue.main.async { submitted(false) }
                return
            }
            // 3.7.3 casts libvlc's 0/-1 result to BOOL. Completion is proved by
            // the started/stopped delegate and validated file, not this return.
            _ = player.startRecording(atPath: path)
            DispatchQueue.main.async { submitted(true) }
        }
    }

    func stopRecording() {
        queue.async { [self] in
            guard !isCancelled else { return }
            _ = player?.stopRecording()
        }
    }

    func retire(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        // Immediately invalidate initialization, queued starts, settings and
        // late callbacks. The queue still owns any native objects until stop.
        cancelled.withLock { $0 = true }
        queue.async { [self] in
            firstFrameProbe?.cancel()
            firstFrameProbe = nil
            guard let player else {
                DispatchQueue.main.async { completion(true) }
                return
            }
            player.delegate = nil
            bridge = nil
            // The synchronous stop waits for the input thread, which can take
            // seconds for an RTSP teardown. Run it beside the SDK queue so
            // other cameras' starts and stops are not queued behind it.
            let retiring = VLCRetiringPlayer(player)
            VLCSDKQueue.blocking.async { [self] in
                let stopped = LumaStopVLCInput(retiring.player)
                queue.async { [self] in finishRetirement(stopped: stopped, completion: completion) }
            }
        }
    }

    private func finishRetirement(stopped: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard stopped, let player else {
            // Never claim release succeeded if a future SDK changes the
            // pinned bridging contract. Retain the player for safety.
            DispatchQueue.main.async { completion(false) }
            return
        }
        // Both setters can acquire libVLC locks. Neither runs on the UI.
        player.drawable = nil
        player.media = nil
        if ownsInterfaceLease {
            VLCInterfaceLeases.shared.release(owner: leaseID)
            ownsInterfaceLease = false
        }
        self.player = nil
        media = nil
        // The native input is fully stopped. Other SDK event references
        // can now expire safely without keeping an active decoder alive.
        DispatchQueue.main.async { completion(true) }
    }

    private func startFirstFrameProbe() {
        guard !firstFrameReported, firstFrameProbe == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isCancelled, self.player?.hasVideoOut == true, let media = self.media else { return }
            let stats = media.statistics
            self.reportFirstFrameIfReady(statsDecoded: stats.decodedVideo, statsDisplayed: stats.displayedPictures)
        }
        firstFrameProbe = timer
        timer.resume()
    }

    private func reportFirstFrameIfReady(statsDecoded: Int32, statsDisplayed: Int32) {
        guard !firstFrameReported, statsDecoded > 0 || statsDisplayed > 0 else { return }
        firstFrameReported = true
        firstFrameProbe?.cancel()
        firstFrameProbe = nil
        // A native Playing event can arrive before vout exists and be filtered
        // above. The frame counters are stronger evidence; publish the normal
        // playback event too so consumers do not depend on TimeChanged (which
        // is not guaranteed for every live input) to leave their loading state.
        emit(.videoPlaying)
        emit(.firstFrame)
    }

    private func enqueue(_ event: VLCPlaybackEvent) {
        queue.async { [self] in
            guard !isCancelled else { return }
            if case .videoPlaying = event {
                // A cached playing notification can precede video output.
                // Confirm the renderer before publishing a playing UI state.
                guard player?.hasVideoOut == true else { return }
            }
            emit(event)
        }
    }

    private func emit(_ event: VLCPlaybackEvent) {
        let recipient = onEvent
        DispatchQueue.main.async { [self] in
            guard !isCancelled else { return }
            recipient(event)
        }
    }
}

/// The one-time SDK event configuration delivers cached-property updates on
/// the SDK queue. MainActor never receives an SDK object or queries its locks.
private final class VLCEventBridge: NSObject, VLCMediaPlayerDelegate {
    private let onEvent: @Sendable (VLCPlaybackEvent) -> Void

    init(onEvent: @escaping @Sendable (VLCPlaybackEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func mediaPlayerStateChanged(_ notification: Notification) {
        dispatchPrecondition(condition: .onQueue(VLCSDKQueue.queue))
        guard let player = notification.object as? VLCMediaPlayer else { return }
        switch player.state {
        case .opening: onEvent(.opening)
        case .buffering: onEvent(.buffering)
        case .playing: onEvent(.videoPlaying)
        case .error: onEvent(.failed)
        case .stopped, .ended, .paused: onEvent(.ended)
        default: break
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        dispatchPrecondition(condition: .onQueue(VLCSDKQueue.queue))
        guard let player = notification.object as? VLCMediaPlayer, player.state == .playing else { return }
        onEvent(.videoPlaying)
    }

    func mediaPlayerSnapshot(_ notification: Notification) {
        dispatchPrecondition(condition: .onQueue(VLCSDKQueue.queue))
        guard let player = notification.object as? VLCMediaPlayer,
              let path = player.snapshots?.last as? String else { return }
        onEvent(.snapshotSaved(path))
    }

    func mediaPlayerStartedRecording(_ player: VLCMediaPlayer) { onEvent(.recordingStarted) }
    func mediaPlayer(_ player: VLCMediaPlayer, recordingStoppedAtPath path: String) { onEvent(.recordingStopped(path)) }
}
