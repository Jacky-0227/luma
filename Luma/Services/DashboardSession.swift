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
    /// Players whose native input did not finish closing within the transition
    /// timeout. They are retained (with their drawables) until they stop.
    private(set) var closingCount = 0
    /// Maintained from player state changes so the viewer observes one value
    /// instead of every player's state.
    private(set) var playingCount = 0

    /// How long a page change waits for the previous page to close before it
    /// continues and leaves slow players closing in the background.
    static let transitionTimeout: Duration = .seconds(8)

    @ObservationIgnored private var desiredCameras: [CameraConfiguration] = []
    @ObservationIgnored private var desiredStore: CameraStore?
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var lingering: [ObjectIdentifier: CameraPlayer] = [:]
    @ObservationIgnored private var stateObservation: Task<Void, Never>?
    @ObservationIgnored private var hiddenIDs: Set<UUID> = []
    @ObservationIgnored private var hideTasks: [UUID: Task<Void, Never>] = [:]

    /// Tiles scrolled off screen stop decoding; scrolling back restarts them.
    func setVisible(_ visible: Bool, for id: UUID) {
        if visible { hiddenIDs.remove(id) } else { hiddenIDs.insert(id) }
        guard !isTransitioning, let camera = cameras.first(where: { $0.id == id }) else { return }
        apply(visible: visible, to: camera)
    }

    /// The viewer reports which tiles start below the first screen.
    func setInitiallyHidden(_ ids: Set<UUID>) {
        hiddenIDs = ids
        guard !isTransitioning else { return }
        for camera in cameras { apply(visible: !ids.contains(camera.id), to: camera) }
    }

    private func apply(visible: Bool, to camera: DashboardCamera) {
        guard let player = camera.player else { return }
        hideTasks.removeValue(forKey: camera.id)?.cancel()
        if visible {
            if wantsPlayback { player.play() }
        } else {
            // A quick scroll past a tile keeps its stream.
            hideTasks[camera.id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.hiddenIDs.contains(camera.id) else { return }
                self.hideTasks[camera.id] = nil
                player.stop()
            }
        }
    }

    func show(_ configurations: [CameraConfiguration], store: CameraStore, active: Bool, forceRestart: Bool = false) {
        // The caller selects the page using DashboardConfiguration. Reject an
        // invalid page as a whole instead of silently displaying a partial page.
        let valid = configurations.count <= 64 && Set(configurations.map(\.id)).count == configurations.count
        let page = valid ? configurations : []
        let shouldPlay = active && !page.isEmpty
        // Visibility and navigation callbacks may report the same state in one
        // transition. Reuse its players instead of rereading Keychain and
        // disposing/reopening identical decoder sessions.
        guard forceRestart || desiredCameras != page || desiredStore !== store || wantsPlayback != shouldPlay else { return }
        desiredCameras = page
        desiredStore = store
        wantsPlayback = shouldPlay
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
        hideTasks.values.forEach { $0.cancel() }
        hideTasks = [:]
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
                await self.waitForClosure(of: retiring)
                guard requestedRevision == self.revision else { continue }
                self.cameras = []
                if self.wantsPlayback, let store = self.desiredStore {
                    self.cameras = self.desiredCameras.map { camera in
                        do {
                            let password = try store.password(for: camera)
                            var preview = camera
                            preview.defaultQuality = .sub
                            let player = CameraPlayer(configuration: preview, password: password,
                                                      playbackProfile: .dashboard, keepsRetrying: true)
                            player.setMuted(true)
                            return DashboardCamera(configuration: camera, player: player, failure: nil)
                        } catch {
                            return DashboardCamera(configuration: camera, player: nil, failure: error.localizedDescription)
                        }
                    }
                    self.cameras.filter { !self.hiddenIDs.contains($0.id) }.forEach { $0.player?.play() }
                }
                self.observePlayerStates()
                self.isTransitioning = false
                self.transition = nil
                return
            }
        }
    }

    /// Waits for every player in parallel, bounded by `transitionTimeout`.
    /// A player still closing afterwards keeps its native input and view; it
    /// is retained here and released once its input has actually stopped.
    private func waitForClosure(of players: [CameraPlayer]) async {
        let stillClosing = await withTaskGroup(of: CameraPlayer?.self) { group in
            for player in players {
                group.addTask { @MainActor in
                    await player.stopAndWait(timeout: Self.transitionTimeout) == .stillClosing ? player : nil
                }
            }
            var result: [CameraPlayer] = []
            for await player in group { if let player { result.append(player) } }
            return result
        }
        for player in stillClosing {
            let id = ObjectIdentifier(player)
            lingering[id] = player
            Task { @MainActor [weak self] in
                // Keep waiting without a practical bound; the player itself
                // reports its failure state after its own retirement watchdog.
                while await player.stopAndWait(timeout: .seconds(60)) == .stillClosing {}
                self?.lingering.removeValue(forKey: id)
                self?.closingCount = self?.lingering.count ?? 0
            }
        }
        closingCount = lingering.count
    }

    private func observePlayerStates() {
        stateObservation?.cancel()
        let players = cameras.compactMap(\.player)
        playingCount = players.filter { $0.state == .playing }.count
        guard !players.isEmpty else { return }
        stateObservation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        for player in players { _ = player.state }
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.playingCount = players.filter { $0.state == .playing }.count
            }
        }
    }
}
