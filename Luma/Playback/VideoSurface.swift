import SwiftUI
import UIKit

/// The camera's real decoded video. UI status and controls belong to the
/// SwiftUI parent so they remain accessible independently of VLC's drawable.
struct VideoSurface: UIViewRepresentable {
    let player: CameraPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> CameraVideoView {
        let view = CameraVideoView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = true
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onLayout = { [weak player, weak view] in
            guard let view else { return }
            player?.surfaceDidLayout(view)
        }
        player.attach(to: view)
        return view
    }

    func updateUIView(_ view: CameraVideoView, context: Context) {
        if context.coordinator.player !== player {
            context.coordinator.player.detach(from: view)
            context.coordinator.player = player
            view.onLayout = { [weak player, weak view] in
                guard let view else { return }
                player?.surfaceDidLayout(view)
            }
        }
        player.attach(to: view)
        player.surfaceDidLayout(view)
    }

    static func dismantleUIView(_ view: CameraVideoView, coordinator: Coordinator) {
        view.onLayout = nil
        coordinator.player.detach(from: view)
    }

    @MainActor
    final class Coordinator {
        var player: CameraPlayer

        init(player: CameraPlayer) {
            self.player = player
        }
    }
}

final class CameraVideoView: UIView {
    var onLayout: (@MainActor () -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
