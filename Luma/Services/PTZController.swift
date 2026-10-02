import Foundation
import Observation

/// One FIFO worker owns all requests. Releasing a button never cancels an in-flight
/// move, because cancellation cannot prove that the camera did not accept it.
@MainActor
@Observable
final class PTZController {
    var errorMessage: String?
    private(set) var isMoving = false

    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let transport: any PTZTransport
    @ObservationIgnored private let holdLimit: Duration
    @ObservationIgnored private var pending: [(command: PTZCommand, generation: Int)] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var repeats = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pulse: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    convenience init(configuration: CameraConfiguration, password: String) {
        self.init(enabled: configuration.ptzEnabled, transport: PTZService(configuration: configuration, password: password))
    }

    init(enabled: Bool, transport: any PTZTransport, holdLimit: Duration = .seconds(2)) {
        self.enabled = enabled
        self.transport = transport
        self.holdLimit = holdLimit
    }

    deinit {
        pulse?.cancel()
        deadline?.cancel()
        // The worker retains its owner until the queue drains; do not cancel it.
    }

    func press(_ direction: PTZDirection) {
        begin(direction, repeats: true)
    }

    /// A VoiceOver activation makes one bounded movement, without requiring a release gesture.
    func nudge(_ direction: PTZDirection) {
        begin(direction, repeats: false)
    }

    private func begin(_ direction: PTZDirection, repeats: Bool) {
        guard enabled else { errorMessage = PTZError.disabled.localizedDescription; return }
        generation += 1
        let current = generation
        self.repeats = repeats
        pulse?.cancel()
        deadline?.cancel()
        pending.removeAll { !$0.command.isStop }
        isMoving = true
        errorMessage = nil
        pending.append((PTZCommand(direction: direction), current))
        startWorker()
        deadline = Task { @MainActor [weak self] in
            guard let selfLimit = self?.holdLimit else { return }
            let limit: Duration = repeats ? selfLimit : .milliseconds(PTZCommand.durationMilliseconds)
            do { try await Task.sleep(for: limit) } catch { return }
            guard let self, self.generation == current else { return }
            self.stop()
        }
    }

    func stop() {
        guard enabled else { return }
        generation += 1
        isMoving = false
        pulse?.cancel()
        pulse = nil
        deadline?.cancel()
        deadline = nil
        pending.removeAll { !$0.command.isStop }
        if pending.last?.command.isStop != true { pending.append((.stop, generation)) }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        // Strong ownership is intentional: a queued stop survives view disposal.
        worker = Task { @MainActor in
            while !self.pending.isEmpty {
                let item = self.pending.removeFirst()
                do {
                    try await self.transport.send(item.command)
                    if !item.command.isStop, self.isMoving, self.repeats, self.generation == item.generation {
                        self.schedulePulse(item.command, generation: item.generation)
                    }
                } catch {
                    self.errorMessage = (error as? PTZError ?? .connectionFailed).localizedDescription
                    if !item.command.isStop { self.stop() }
                }
            }
            self.worker = nil
        }
    }

    private func schedulePulse(_ command: PTZCommand, generation: Int) {
        pulse?.cancel()
        pulse = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.isMoving, self.generation == generation else { return }
            self.pending.append((command, generation))
            self.startWorker()
        }
    }
}
