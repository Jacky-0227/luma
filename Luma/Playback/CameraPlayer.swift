import Foundation
import Observation
import OSLog
import UIKit

enum PlaybackState: Equatable, Sendable {
    case idle
    case connecting
    case playing
    case buffering
    case failed(String)
}

/// UI-owned playback state. Camera credentials never leave the device or enter logs.
@MainActor
@Observable
final class CameraPlayer {
    private(set) var state: PlaybackState = .idle
    private(set) var isMuted = true
    private(set) var quality: StreamQuality
    private(set) var aspectFill = false
    private(set) var captureState: CaptureState = .idle
    private(set) var captureMessage: String?
    private(set) var captureError: String?
    private(set) var recordingStartedAt: Date?

    @ObservationIgnored private let configuration: CameraConfiguration
    @ObservationIgnored private let password: String
    @ObservationIgnored private let savesPreview: Bool
    @ObservationIgnored private let thumbnailStore: CameraThumbnailStore?
    @ObservationIgnored private var previewCaptured = false
    @ObservationIgnored private var previewRequestID: UUID?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @MainActor private final class PreviewLifetime {
        var preservesSnapshot = false
    }
    @ObservationIgnored private weak var surface: UIView?
    @ObservationIgnored private var session: VLCPlaybackSession?
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var isRetiring = false
    @ObservationIgnored private var retryReady = true
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var retirementWatchdog: Task<Void, Never>?
    @ObservationIgnored private var retirementTimedOut = false
    @ObservationIgnored private var lastPlaybackActivity = ContinuousClock.now
    @ObservationIgnored private var sessionStartedAt = ContinuousClock.now
    @ObservationIgnored private var firstFrameLogged = false
    @ObservationIgnored private var hasStartedPlayback = false
    @ObservationIgnored private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: CameraConfiguration, password: String, savesPreview: Bool = false,
         thumbnailStore: CameraThumbnailStore? = nil) {
        self.configuration = configuration
        self.password = password
        self.savesPreview = savesPreview
        self.thumbnailStore = thumbnailStore
        self.quality = configuration.defaultQuality
    }

    deinit {
        retryTask?.cancel()
        watchdogTask?.cancel()
        retirementWatchdog?.cancel()
        previewTask?.cancel()
        // The session is MainActor isolated (and therefore Sendable). Its SDK
        // references are only touched after hopping back to their owning actor.
        let orphanedSession = session
        Task { @MainActor in
            orphanedSession?.retire()
        }
    }

    func attach(to view: UIView) {
        guard surface !== view else { return }
        let isReplacingSurface = surface != nil
        surface = view
        if isReplacingSurface, session != nil {
            restart()
        } else {
            beginIfReady()
        }
    }

    /// Stop only if this is still the active representable. A disappearing old
    /// SwiftUI surface must not detach a newly attached full-screen surface.
    func detach(from view: UIView) {
        guard surface === view else { return }
        stop()
        surface = nil
    }

    func surfaceDidLayout(_ view: UIView) {
        guard surface === view else { return }
        session?.setAspectFill(aspectFill, bounds: view.bounds)
    }

    func play() {
        guard !wantsPlayback else { return }
        guard !isRetiring || !retirementTimedOut else {
            state = .failed(Self.closingMessage)
            return
        }
        wantsPlayback = true
        reconnectAttempt = 0
        retryReady = true
        state = .connecting
        beginIfReady()
    }

    func stop() {
        wantsPlayback = false
        cancelScheduledWork()
        state = .idle
        retireCurrentSession()
    }

    /// Dashboard transitions can stop every stream first, then await each
    /// decoder/capture teardown before creating a new set of players.
    func stopAndWait() async {
        stop()
        guard isRetiring else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func captureSnapshot() {
        guard state == .playing, captureState == .idle else { return }
        dismissCaptureFeedback()
        session?.captureSnapshot()
    }

    func toggleRecording() {
        guard captureState == .recording || captureState == .startingRecording
            || (state == .playing && captureState == .idle) else { return }
        dismissCaptureFeedback()
        session?.toggleRecording()
    }

    func dismissCaptureFeedback() {
        captureMessage = nil
        captureError = nil
    }

    func retry() {
        guard !isRetiring || !retirementTimedOut else {
            state = .failed(Self.closingMessage)
            return
        }
        wantsPlayback = true
        reconnectAttempt = 0
        restart()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        session?.setMuted(muted)
    }

    func setQuality(_ value: StreamQuality) {
        guard quality != value else { return }
        quality = value
        reconnectAttempt = 0
        if wantsPlayback { restart() }
    }

    func setAspectFill(_ value: Bool) {
        aspectFill = value
        if let surface {
            session?.setAspectFill(value, bounds: surface.bounds)
        }
    }

    private func restart() {
        cancelScheduledWork()
        retryReady = true
        if wantsPlayback { state = .connecting }
        retireCurrentSession()
        beginIfReady()
    }

    private func beginIfReady() {
        guard wantsPlayback, retryReady, !isRetiring,
              session == nil, let surface else { return }

        let url: URL
        do {
            url = try configuration.streamURL(password: password, quality: quality)
        } catch {
            wantsPlayback = false
            // Validation errors can contain user input. Never display the raw
            // URL, SDK error text, or an interpolated authentication failure.
            state = .failed(String(localized: "Check the camera address and connection settings."))
            return
        }

        state = .connecting
        let nextSession = VLCPlaybackSession(url: url, useTCP: configuration.useTCP)
        let id = nextSession.id
        nextSession.onEvent = { [weak self] event in
            self?.receive(event, from: id)
        }
        nextSession.onCaptureEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .state(let captureState):
                self.captureState = captureState
                if captureState == .idle { self.recordingStartedAt = nil }
            case .recordingStarted(let date):
                self.recordingStartedAt = date
            case .saved(let kind):
                self.captureMessage = kind == .snapshot
                    ? String(localized: "Snapshot saved to Library.")
                    : String(localized: "Recording saved to Library.")
            case .failed(let message):
                self.captureError = message
            }
        }
        session = nextSession
        lastPlaybackActivity = .now
        sessionStartedAt = .now
        firstFrameLogged = false
        hasStartedPlayback = false
        nextSession.start(on: surface, muted: isMuted, aspectFill: aspectFill)
        armWatchdog(for: id)
    }

    private func receive(_ event: VLCPlaybackEvent, from id: UUID) {
        guard wantsPlayback, let session, session.id == id else { return }
        switch event {
        case .opening:
            state = .connecting
            armWatchdog(for: id)
        case .buffering:
            // Do not restart the timeout for repeated buffering notifications.
            // Otherwise an unreachable stream could show a spinner forever.
            state = .buffering
            armWatchdog(for: id)
        case .videoPlaying:
            lastPlaybackActivity = .now
            hasStartedPlayback = true
            if state != .playing {
                state = .playing
                session.setMuted(isMuted)
                if let surface {
                    session.setAspectFill(aspectFill, bounds: surface.bounds)
                }
            }
        case .firstFrame:
            guard !firstFrameLogged else { return }
            firstFrameLogged = true
            let elapsed = sessionStartedAt.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            Self.performanceLog.notice("first_frame elapsed_ms=\(milliseconds, privacy: .public)")
            receive(.videoPlaying, from: id)
            savePreviewIfNeeded(from: session)
        case .routeConflict:
            wantsPlayback = false
            cancelScheduledWork()
            state = .failed(String(localized: "This camera uses a different network interface. Stop other cameras before reconnecting."))
            retireCurrentSession()
        case .routeUnavailable:
            recoverOrFail(String(localized: "No local IPv4 route is available for this camera. Check your Wi-Fi connection."))
        case .failed, .ended:
            recoverOrFail(String(localized: "Unable to play this camera. Check its address, account, and Wi-Fi connection."))
        case .snapshotSaved, .recordingStarted, .recordingStopped:
            break // Capture events are handled by the session before forwarding.
        }
    }

    private func savePreviewIfNeeded(from source: VLCPlaybackSession) {
        guard savesPreview, !previewCaptured, previewRequestID == nil, let thumbnailStore else { return }
        // One successful snapshot per visit. A replacement session may retry an
        // interrupted attempt, without a timer or any delay to starting video.
        let requestID = UUID()
        previewRequestID = requestID
        let camera = configuration
        let sessionID = source.id
        previewTask = Task { @MainActor [weak self, weak source] in
            defer {
                // A canceled old task must not clear a newer session's request.
                if self?.previewRequestID == requestID {
                    self?.previewRequestID = nil
                    self?.previewTask = nil
                }
            }
            guard let ticket = await thumbnailStore.prepareCapture(for: camera) else { return }
            guard !Task.isCancelled, let source, self?.wantsPlayback == true,
                  self?.session?.id == sessionID, self?.previewRequestID == requestID else {
                await thumbnailStore.discard(ticket)
                return
            }
            let lifetime = PreviewLifetime()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                source.capturePreview(at: ticket.fileURL, cleanup: {
                    // Once the SDK has produced the image, its independent save
                    // owns staging cleanup. Retirement must not revoke that save.
                    if !lifetime.preservesSnapshot { Task { await thumbnailStore.discard(ticket) } }
                }) { [weak self] success in
                    if success {
                        lifetime.preservesSnapshot = true
                        if self?.previewRequestID == requestID { self?.previewCaptured = true }
                        // A captured frame remains valid when the user returns
                        // home or changes quality while ImageIO is compressing.
                        Task { await thumbnailStore.save(ticket) }
                    } else {
                        Task { await thumbnailStore.discard(ticket) }
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func armWatchdog(for id: UUID) {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            // The initial identity check is UI-owned. Task.sleep suspends and
            // does not occupy the main thread while the stream opens.
            guard self?.session?.id == id else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                      self.wantsPlayback, self.session?.id == id else { return }
                self.session?.pollVideoProgress()
                // Also catch a stream that silently freezes after it started.
                // Buffering notifications do not count as advancing video.
                // Established streams get more time for a temporary Wi-Fi gap.
                // RTSP may prepare video and audio separately. On real iOS
                // hardware live555 can spend ~10 seconds per track before
                // SETUP; 15 seconds cut off a valid authenticated connection.
                // Keep a finite startup deadline that covers both tracks.
                let timeout: Duration = self.hasStartedPlayback ? .seconds(30) : .seconds(45)
                if self.lastPlaybackActivity.duration(to: .now) >= timeout {
                    self.watchdogTask = nil
                    self.recoverOrFail(String(localized: "The camera did not respond. Check Local Network access in Settings and connect to the same Wi-Fi."))
                    return
                }
            }
        }
    }

    private func recoverOrFail(_ message: String) {
        cancelScheduledWork()
        // Three automatic retries per explicit play/retry action. A briefly
        // successful stream does not reset this budget and create an endless loop.
        guard reconnectAttempt < 3 else {
            wantsPlayback = false
            state = .failed(message)
            retireCurrentSession()
            return
        }

        let delay = 1 << reconnectAttempt // 1, 2, 4 seconds
        reconnectAttempt += 1
        retryReady = false
        state = .connecting
        retireCurrentSession()
        retryTask = Task { @MainActor [weak self] in
            guard self?.wantsPlayback == true else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.wantsPlayback else { return }
            self.retryTask = nil
            self.retryReady = true
            self.beginIfReady()
        }
    }

    private func retireCurrentSession() {
        previewTask?.cancel()
        previewTask = nil
        previewRequestID = nil
        guard let retiringSession = session else { return }
        session = nil
        isRetiring = true
        retirementTimedOut = false
        retirementWatchdog?.cancel()
        retirementWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard !Task.isCancelled, let self, self.isRetiring else { return }
            self.retirementTimedOut = true
            self.wantsPlayback = false
            self.cancelScheduledWork()
            self.state = .failed(Self.closingMessage)
            // Do not resume stopAndWait or create another decoder here.
            // The native input and its view remain owned until actual stop.
        }
        retiringSession.retire { [weak self] in
            guard let self else { return }
            self.retirementWatchdog?.cancel()
            self.retirementWatchdog = nil
            self.retirementTimedOut = false
            self.isRetiring = false
            let waiters = self.stopWaiters
            self.stopWaiters = []
            for waiter in waiters { waiter.resume() }
            self.beginIfReady()
        }
    }

    private static var closingMessage: String {
        String(localized: "The previous stream is still closing. Wait a moment, then reconnect.")
    }

    // Local timing only: no host, device name, URL, credential or telemetry.
    private static let performanceLog = Logger(subsystem: "app.luma.viewer", category: "Playback")

    private func cancelScheduledWork() {
        retryTask?.cancel()
        retryTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }
}
