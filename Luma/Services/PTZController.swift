import Foundation
import Observation
import UIKit

/// One FIFO worker owns all requests. Never cancel an in-flight move: a client
/// timeout or cancellation cannot prove that the camera did not accept it.
@MainActor
@Observable
final class PTZController {
    var errorMessage: String?
    private(set) var isMoving = false
    private(set) var isStopping = false
    var supportsPanTilt: Bool { capabilities.panMode != nil || capabilities.tiltMode != nil }
    var supportsZoom: Bool { capabilities.zoomMode != nil }
    var usesContinuousControl: Bool {
        [capabilities.panMode, capabilities.tiltMode, capabilities.zoomMode].contains(.continuous)
    }
    var isContinuousMode: Bool { usesContinuousControl }

    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let transport: any PTZTransport
    @ObservationIgnored private let capabilities: PTZCapabilities
    @ObservationIgnored private let holdLimit: Duration
    @ObservationIgnored private let stopRetryDelay: Duration
    @ObservationIgnored private var pending: [(command: PTZCommand, generation: Int)] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var repeats = false
    @ObservationIgnored private var stopInFlight = false
    @ObservationIgnored private var stopFailed = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pulse: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundDeadline: Task<Void, Never>?

    convenience init(configuration: CameraConfiguration, password: String, capabilities: PTZCapabilities) {
        // Detected capabilities, rather than a persisted legacy toggle, authorize
        // this controller. Keep the selected control channel independent of RTSP.
        var controls = configuration
        controls.ptzEnabled = true
        controls.ptzChannel = capabilities.channel
        self.init(enabled: true, transport: PTZService(configuration: controls, password: password), capabilities: capabilities)
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
        // The deadline retains us until Stop is queued, and the worker until
        // all stop attempts finish and its background allowance is ended.
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

    func press(_ direction: PTZDirection) { begin(direction, repeats: true) }

    /// VoiceOver activation requests a short movement without a release gesture.
    func nudge(_ direction: PTZDirection) { begin(direction, repeats: false) }

    private func begin(_ direction: PTZDirection, repeats: Bool) {
        guard enabled else { errorMessage = PTZError.disabled.localizedDescription; return }
        guard !isStopping else {
            errorMessage = PTZError.stopUnconfirmed.localizedDescription
            return
        }
        guard let mode = mode(for: direction) else { errorMessage = PTZError.unsupported.localizedDescription; return }
        generation += 1
        let current = generation
        self.repeats = repeats && mode == .momentary
        pulse?.cancel()
        deadline?.cancel()
        pending.removeAll { !$0.command.isStop }
        isMoving = true
        errorMessage = nil
        beginBackgroundAllowance()
        pending.append((PTZCommand(direction: direction, mode: mode), current))
        startWorker()
        let limit: Duration = repeats ? holdLimit : .milliseconds(PTZCommand.durationMilliseconds)
        // Keep this bounded owner alive even if the presentation vanishes just
        // after the move reply and before SwiftUI delivers onDisappear.
        deadline = Task { @MainActor [self] in
            do { try await Task.sleep(for: limit) } catch { return }
            guard generation == current else { return }
            stop()
        }
    }

    func stop() {
        guard enabled else { return }
        generation += 1
        isMoving = false
        isStopping = true
        pulse?.cancel()
        pulse = nil
        deadline?.cancel()
        deadline = nil
        pending.removeAll { !$0.command.isStop }
        // Repeated release/scene callbacks must not enqueue endless retry batches.
        guard !stopInFlight, !pending.contains(where: { $0.command.isStop }) else { return }
        beginBackgroundAllowance()
        let mode: PTZMovementMode = capabilities.supportsContinuousStop ? .continuous : .momentary
        pending.append((.stop(mode: mode), generation))
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        // Strong ownership intentionally keeps queued Stop alive after view disposal.
        worker = Task { @MainActor in
            while !self.pending.isEmpty {
                let item = self.pending.removeFirst()
                if item.command.isStop {
                    await self.sendStop(item.command)
                    continue
                }
                guard self.isMoving, !self.isStopping, self.generation == item.generation else { continue }
                do {
                    try await self.transport.send(item.command)
                    if self.isMoving, self.repeats, self.generation == item.generation {
                        self.schedulePulse(item.command, generation: item.generation)
                    }
                } catch {
                    self.errorMessage = (error as? PTZError ?? .connectionFailed).localizedDescription
                    self.stop()
                }
            }
            self.worker = nil
            if !self.isMoving { self.endBackgroundAllowance() }
        }
    }

    private func sendStop(_ command: PTZCommand) async {
        stopInFlight = true
        defer { stopInFlight = false }
        for attempt in 0...2 {
            do {
                try await transport.send(command)
                isStopping = false
                if stopFailed || errorMessage == PTZError.stopUnconfirmed.localizedDescription { errorMessage = nil }
                stopFailed = false
                return
            } catch {
                stopFailed = true
                errorMessage = PTZError.stopUnconfirmed.localizedDescription
                if attempt < 2 { try? await Task.sleep(for: stopRetryDelay) }
            }
        }
        // Remain stopped at the command layer and block further motion. The user
        // can explicitly retry Stop; never report physical stop without an ACK.
        isStopping = true
        pending.removeAll { !$0.command.isStop }
    }

    private func schedulePulse(_ command: PTZCommand, generation: Int) {
        guard command.mode == .momentary else { return }
        pulse?.cancel()
        pulse = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.isMoving, !self.isStopping, self.generation == generation else { return }
            self.pending.append((command, generation))
            self.startWorker()
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

    private func endBackgroundAllowance() {
        backgroundDeadline?.cancel()
        backgroundDeadline = nil
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}
