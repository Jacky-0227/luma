import Foundation
import Observation

struct DashboardCamera: Identifiable {
    let configuration: CameraConfiguration
    let player: CameraPlayer?
    let failure: String?
    var id: UUID { configuration.id }
}

/// Owns only the visible page's decoders. Every transition stops the old page
/// before opening any replacement streams; a stale async transition cannot play.
@MainActor
@Observable
final class DashboardSession {
    private(set) var cameras: [DashboardCamera] = []
    private(set) var isTransitioning = false

    @ObservationIgnored private var desiredCameras: [CameraConfiguration] = []
    @ObservationIgnored private var desiredStore: CameraStore?
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var transition: Task<Void, Never>?

    func show(_ configurations: [CameraConfiguration], store: CameraStore, active: Bool, forceRestart: Bool = false) {
        let page = Array(configurations.prefix(4))
        // Visibility and navigation callbacks may report the same state in one
        // transition. Reuse its players instead of rereading Keychain and
        // disposing/reopening up to four identical decoder sessions.
        guard forceRestart || desiredCameras != page || desiredStore !== store || wantsPlayback != active else { return }
        desiredCameras = page
        desiredStore = store
        wantsPlayback = active
        scheduleTransition()
    }

    func suspend() {
        wantsPlayback = false
        // Stop synchronously in the view lifecycle callback, before an async task
        // gets its turn. This also cancels each player's reconnection work.
        cameras.forEach { $0.player?.stop() }
        scheduleTransition()
    }

    func suspendAndWait() async {
        suspend()
        if let transition { await transition.value }
    }

    private func scheduleTransition() {
        revision &+= 1
        cameras.forEach { $0.player?.stop() }
        isTransitioning = true
        guard transition == nil else { return }
        transition = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                let requestedRevision = self.revision
                let retiring = self.cameras.compactMap(\.player)
                // Stop everyone first, then wait: disposal work runs concurrently
                // with these awaits and no replacement is opened early.
                retiring.forEach { $0.stop() }
                for player in retiring { await player.stopAndWait() }
                guard requestedRevision == self.revision else { continue }
                self.cameras = []
                if self.wantsPlayback, let store = self.desiredStore {
                    self.cameras = self.desiredCameras.map { camera in
                        do {
                            let password = try store.password(for: camera)
                            var preview = camera
                            preview.defaultQuality = .sub
                            let player = CameraPlayer(configuration: preview, password: password)
                            player.setMuted(true)
                            return DashboardCamera(configuration: camera, player: player, failure: nil)
                        } catch {
                            return DashboardCamera(configuration: camera, player: nil, failure: error.localizedDescription)
                        }
                    }
                    self.cameras.forEach { $0.player?.play() }
                }
                self.isTransitioning = false
                self.transition = nil
                return
            }
        }
    }
}
