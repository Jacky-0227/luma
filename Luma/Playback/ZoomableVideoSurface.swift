import SwiftUI
import UIKit

/// Keep one native drawable for both normal and full-screen playback. Zooming
/// transforms that drawable locally; it never restarts VLC or sends PTZ commands.
struct ZoomableVideoSurface: UIViewRepresentable {
    let player: CameraPlayer
    let isZoomEnabled: Bool
    let resetID: UUID

    func makeCoordinator() -> VideoSurface.Coordinator {
        VideoSurface.Coordinator(player: player)
    }

    func makeUIView(context: Context) -> ZoomableCameraVideoView {
        let view = ZoomableCameraVideoView()
        connect(view.videoView)
        view.configure(enabled: isZoomEnabled, resetID: resetID)
        return view
    }

    func updateUIView(_ view: ZoomableCameraVideoView, context: Context) {
        if context.coordinator.player !== player {
            context.coordinator.player.detach(from: view.videoView)
            context.coordinator.player = player
            connect(view.videoView)
            view.resetZoom()
        }
        view.configure(enabled: isZoomEnabled, resetID: resetID)
    }

    static func dismantleUIView(_ view: ZoomableCameraVideoView, coordinator: VideoSurface.Coordinator) {
        view.videoView.onLayout = nil
        coordinator.player.detach(from: view.videoView)
    }

    private func connect(_ surface: CameraVideoView) {
        surface.onLayout = { [weak player, weak surface] in
            guard let surface else { return }
            player?.surfaceDidLayout(surface)
        }
        player.attach(to: surface)
    }
}

/// UIScrollView handles the pinch focal point, simultaneous panning and edge
/// constraints on the main thread without updating the SwiftUI tree each frame.
final class ZoomableCameraVideoView: UIScrollView, UIScrollViewDelegate {
    let videoView = CameraVideoView()
    private var viewportSize: CGSize = .zero
    private var lastResetID: UUID?
    private(set) var zoomEnabled = false

    init() {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = false
        bouncesZoom = false
        minimumZoomScale = 1
        maximumZoomScale = 1
        videoView.backgroundColor = .black
        videoView.isOpaque = true
        videoView.clipsToBounds = true
        videoView.isUserInteractionEnabled = false
        videoView.accessibilityElementsHidden = true
        addSubview(videoView)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Camera video")
        accessibilityIdentifier = "player.video"
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(enabled: Bool, resetID: UUID) {
        if !enabled || (lastResetID != nil && lastResetID != resetID) { resetZoom() }
        lastResetID = resetID
        zoomEnabled = enabled
        maximumZoomScale = enabled ? 6 : 1
        pinchGestureRecognizer?.isEnabled = enabled
        panGestureRecognizer.isEnabled = enabled
        updateAccessibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != viewportSize, bounds.width > 0, bounds.height > 0 else { return }
        viewportSize = bounds.size
        // A rotation or full-screen transition changes the viewport, not the
        // camera's aspect ratio. Start centered while retaining the same decoder.
        resetZoom()
        videoView.bounds = CGRect(origin: .zero, size: viewportSize)
        videoView.center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        contentSize = viewportSize
        setContentOffset(.zero, animated: false)
    }

    func resetZoom() {
        setZoomScale(1, animated: false)
        setContentOffset(.zero, animated: false)
        updateAccessibility()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomEnabled ? videoView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateAccessibility() }

    override func accessibilityIncrement() {
        guard zoomEnabled else { return }
        setZoomScale(min(maximumZoomScale, zoomScale + 0.5), animated: false)
    }

    override func accessibilityDecrement() {
        guard zoomEnabled else { return }
        setZoomScale(max(minimumZoomScale, zoomScale - 0.5), animated: false)
    }

    private func updateAccessibility() {
        accessibilityTraits = zoomEnabled ? [.image, .adjustable] : [.image]
        accessibilityValue = String(format: "%.1f×", locale: Locale.current, Double(zoomScale))
        accessibilityHint = zoomEnabled ? String(localized: "Pinch to zoom, then drag to look around.") : nil
    }
}
