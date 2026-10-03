import Foundation
import Observation
import UIKit

/// At most one movement request and one independent Stop request are in flight.
/// Stop never waits for movement's HTTP response. An obsolete movement settling
/// after Stop was issued requires another Stop, even if the first Stop succeeded.
@MainActor
@Observable
final class PTZController {
    var errorMessage: String?
    private(set) var isMoving = false
    private(set) var isStopping = false
    private(set) var isBlocked = false
    var supportsPanTilt: Bool { capabilities.panMode != nil || capabilities.tiltMode != nil }
    var supportsZoom: Bool { capabilities.zoomMode != nil }
    var usesContinuousControl: Bool {
        [capabilities.panMode, capabilities.tiltMode, capabilities.zoomMode].contains(.continuous)
    }
    var isContinuousMode: Bool { usesContinuousControl }

    private struct Intent {
        let token: UUID
        let command: PTZCommand
        let repeats: Bool
    }

    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let transport: any PTZTransport
    @ObservationIgnored private let capabilities: PTZCapabilities
    @ObservationIgnored private let holdLimit: Duration
    @ObservationIgnored private let stopRetryDelay: Duration
    @ObservationIgnored private var desired: Intent?
    @ObservationIgnored private var issuedMoveRevision = 0
    @ObservationIgnored private var settledMoveRevision = 0
    @ObservationIgnored private var activeMove: (token: UUID, revision: Int)?
    @ObservationIgnored private var moveTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var stopFailed = false
    @ObservationIgnored private var pulse: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundDeadline: Task<Void, Never>?

    convenience init(configuration: CameraConfiguration, password: String, capabilities: PTZCapabilities) {
        var controls = configuration
        controls.ptzEnabled = true
        controls.ptzChannel = capabilities.channel
        self.init(enabled: true,
                  transport: PTZService(configuration: controls, password: password, apiFamily: capabilities.apiFamily),
                  capabilities: capabilities)
    }

    convenience init(configuration: CameraConfiguration, password: String, supportsPanTilt: Bool = true, supportsZoom: Bool = true) {
        self.init(enabled: configuration.ptzEnabled, transport: PTZService(configuration: configuration, password: password),
                  supportsPanTilt: supportsPanTilt, supportsZoom: supportsZoom)
    }

    convenience init(enabled: Bool, transport: any PTZTransport, holdLimit: Duration = .seconds(2), supportsPanTilt: Bool = true, supportsZoom: Bool = true) {
        self.init(enabled: enabled, transport: transport,
                  capabilities: PTZCapabilities(channel: 1, panTilt: supportsPanTilt, zoom: supportsZoom), holdLimit: holdLimit)
    }

    init(enabled: Bool, transport: any PTZTransport, capabilities: PTZCapabilities,
         holdLimit: Duration = .seconds(2), stopRetryDelay: Duration = .milliseconds(150)) {
        self.enabled = enabled
        self.transport = transport
        self.capabilities = capabilities
        self.holdLimit = holdLimit
        self.stopRetryDelay = stopRetryDelay
    }

    deinit {
        pulse?.cancel()
        deadline?.cancel()
        backgroundDeadline?.cancel()
        // Request tasks and the bounded hold deadline retain their owner.
        // Never cancel a movement request as a substitute for stopping a camera.
    }

    func supports(_ direction: PTZDirection) -> Bool { mode(for: direction) != nil }

    private func mode(for direction: PTZDirection) -> PTZMovementMode? {
        switch direction {
        case .left, .right: return capabilities.panMode
        case .up, .down: return capabilities.tiltMode
        case .zoomIn, .zoomOut: return capabilities.zoomMode
        case .upLeft, .upRight, .downLeft, .downRight:
            guard let pan = capabilities.panMode, pan == capabilities.tiltMode else { return nil }
            return pan
        }
    }

    @discardableResult
    func press(_ direction: PTZDirection) -> UUID? { begin(direction, repeats: true) }

    /// Owned by the visible live view's task. Cancellation stops readiness reads;
    /// movement and compensating Stop retain their separate safety lifecycle.
    func keepConnectionReady() async {
        guard enabled else { return }
        while !Task.isCancelled {
            if !isMoving && !isStopping && !isBlocked { await transport.prepare() }
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
        }
    }

    func release(token: UUID) {
        guard desired?.token == token else { return }
        stop()
    }

    /// VoiceOver activation requests a short movement without a release gesture.
    func nudge(_ direction: PTZDirection) { _ = begin(direction, repeats: false) }

    private func begin(_ direction: PTZDirection, repeats: Bool) -> UUID? {
        guard enabled else { errorMessage = PTZError.disabled.localizedDescription; return nil }
        guard !isBlocked else { errorMessage = PTZError.stopUnconfirmed.localizedDescription; return nil }
        guard let mode = mode(for: direction) else { errorMessage = PTZError.unsupported.localizedDescription; return nil }
        let intent = Intent(token: UUID(), command: PTZCommand(direction: direction, mode: mode),
                            repeats: repeats && mode == .momentary)
        desired = intent
        pulse?.cancel()
        pulse = nil
        deadline?.cancel()
        isMoving = true
        errorMessage = nil
        beginBackgroundAllowance()

        if activeMove != nil {
            // Keep only the newest still-held intent. Stop the previous command
            // immediately; don't send competing directional requests out of order.
            isStopping = true
            ensureStopTask()
        } else if isStopping {
            ensureStopTask()
        } else {
            sendDesiredMove()
        }

        let limit: Duration = repeats ? holdLimit : .milliseconds(PTZCommand.durationMilliseconds)
        deadline = Task { @MainActor [self] in
            do { try await Task.sleep(for: limit) } catch { return }
            release(token: intent.token)
        }
        return intent.token
    }

    /// Explicit Stop and lifecycle teardown clear every queued/held intent.
    func stop() {
        guard enabled else { return }
        clearIntent()
        isStopping = true
        beginBackgroundAllowance()
        ensureStopTask()
    }

    private func clearIntent() {
        desired = nil
        isMoving = false
        pulse?.cancel()
        pulse = nil
        deadline?.cancel()
        deadline = nil
    }

    private func sendDesiredMove() {
        guard !isStopping, !isBlocked, activeMove == nil, let intent = desired else { return }
        issuedMoveRevision += 1
        let revision = issuedMoveRevision
        activeMove = (intent.token, revision)
        let sentAt = ContinuousClock.now
        moveTask = Task { @MainActor [self] in
            // Touch-up or a replacement touch can arrive before this task gets
            // its first turn. An unsent obsolete command must never reach the
            // camera; already-issued HTTP requests are still allowed to settle.
            guard desired?.token == intent.token, !isStopping, !isBlocked else {
                activeMove = nil
                moveTask = nil
                if isStopping { ensureStopTask() }
                finishBackgroundAllowanceIfIdle()
                return
            }
            var failure: PTZError?
            do { try await transport.send(intent.command) }
            catch { failure = error as? PTZError ?? .connectionFailed }
            // There is only one movement lane. A completion may be obsolete, but
            // it must still update Stop coverage and never revive its old intent.
            settledMoveRevision = revision
            activeMove = nil
            moveTask = nil
            if let failure, desired?.token == intent.token {
                errorMessage = failure.localizedDescription
                clearIntent()
                isStopping = true
            }
            if isStopping || desired?.token != intent.token {
                isStopping = true
                ensureStopTask()
            } else if intent.repeats {
                schedulePulse(intent, sentAt: sentAt)
            }
            finishBackgroundAllowanceIfIdle()
        }
    }

    private func ensureStopTask() {
        guard stopTask == nil else { return }
        stopTask = Task { @MainActor [self] in
            let stopMode: PTZMovementMode = capabilities.supportsContinuousStop ? .continuous : .momentary
            let command = PTZCommand.stop(mode: stopMode)
            while true {
                // A Stop only covers movements already settled when it is sent.
                // Its ACK arriving after a move's ACK does not establish the
                // camera's command execution order across HTTP connections.
                let coverage = settledMoveRevision
                var confirmed = false
                for attempt in 0...2 {
                    do {
                        try await transport.send(command)
                        confirmed = true
                        break
                    } catch {
                        stopFailed = true
                        errorMessage = PTZError.stopUnconfirmed.localizedDescription
                        if attempt < 2 { try? await Task.sleep(for: stopRetryDelay) }
                    }
                }
                if !confirmed {
                    clearIntent()
                    isBlocked = true
                    isStopping = true
                    stopTask = nil
                    finishBackgroundAllowanceIfIdle()
                    return
                }
                if activeMove != nil {
                    // The old movement task keeps us alive. Its eventual success,
                    // rejection, or timeout will trigger a final compensating Stop.
                    stopTask = nil
                    return
                }
                if coverage != settledMoveRevision {
                    // A movement settled while this Stop was in flight. Issue a
                    // fresh Stop now; don't mistake an early Stop ACK for safety.
                    continue
                }
                isStopping = false
                isBlocked = false
                if stopFailed || errorMessage == PTZError.stopUnconfirmed.localizedDescription { errorMessage = nil }
                stopFailed = false
                stopTask = nil
                sendDesiredMove()
                finishBackgroundAllowanceIfIdle()
                return
            }
        }
    }

    private func schedulePulse(_ intent: Intent, sentAt: ContinuousClock.Instant) {
        guard intent.command.mode == .momentary else { return }
        pulse?.cancel()
        pulse = Task { @MainActor [weak self] in
            // Don't add a fixed 300 ms delay on top of HTTP response latency.
            let delay = ContinuousClock.now.duration(to: sentAt.advanced(by: .milliseconds(300)))
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, self.desired?.token == intent.token, !self.isStopping, !self.isBlocked else { return }
            self.sendDesiredMove()
        }
    }

    private func beginBackgroundAllowance() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PTZ stop") { [weak self] in
            Task { @MainActor [weak self] in
                self?.stop()
                self?.endBackgroundAllowance()
            }
        }
        backgroundDeadline?.cancel()
        backgroundDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            self?.stop()
            self?.endBackgroundAllowance()
        }
    }

    private func finishBackgroundAllowanceIfIdle() {
        if desired == nil, activeMove == nil, stopTask == nil { endBackgroundAllowance() }
    }

    private func endBackgroundAllowance() {
        backgroundDeadline?.cancel()
        backgroundDeadline = nil
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}
