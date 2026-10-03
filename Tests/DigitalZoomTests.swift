import UIKit
import XCTest
@testable import Luma

final class DigitalZoomTests: XCTestCase {
    @MainActor
    func testZoomScalesUniformlyAndRetainsTheDrawable() {
        let view = ZoomableCameraVideoView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        view.layoutIfNeeded()
        let surface = view.videoView
        let sourceBounds = surface.bounds
        let resetID = UUID()
        view.configure(enabled: true, resetID: resetID)
        view.setZoomScale(3, animated: false)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 3, accuracy: 0.001)
        XCTAssertEqual(surface.bounds, sourceBounds, "Display zoom must not resize the native video coordinate space.")
        XCTAssertEqual(surface.transform.a, surface.transform.d, accuracy: 0.001)
        XCTAssertEqual(surface.transform.a, 3, accuracy: 0.001)
        view.setContentOffset(CGPoint(x: 150, y: 200), animated: false)
        XCTAssertGreaterThan(view.contentOffset.x, 0)
        view.configure(enabled: true, resetID: resetID)
        XCTAssertEqual(view.zoomScale, 3, "Ordinary SwiftUI updates must preserve the current zoom.")
        view.configure(enabled: true, resetID: UUID())
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertEqual(view.contentOffset, .zero)
        XCTAssertTrue(surface === view.videoView, "Reset must preserve the video attachment.")
    }

    @MainActor
    func testExitFullscreenAndRotationRestoreTheWholeImage() {
        let view = ZoomableCameraVideoView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        view.layoutIfNeeded()
        let resetID = UUID()
        view.configure(enabled: true, resetID: resetID)
        view.setZoomScale(4, animated: false)
        view.configure(enabled: false, resetID: resetID)
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertEqual(view.contentOffset, .zero)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
        XCTAssertFalse(view.pinchGestureRecognizer?.isEnabled ?? true)
        view.configure(enabled: true, resetID: resetID)
        view.setZoomScale(2, animated: false)
        view.frame.size = CGSize(width: 780, height: 390)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertEqual(view.videoView.bounds.size, view.bounds.size)
        XCTAssertEqual(view.contentOffset, .zero)
    }

    @MainActor
    func testVoiceOverZoomIsBoundedAndOnlyAvailableFullscreen() {
        let view = ZoomableCameraVideoView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        view.layoutIfNeeded()
        view.accessibilityIncrement()
        XCTAssertEqual(view.zoomScale, 1)
        view.configure(enabled: true, resetID: UUID())
        for _ in 0..<20 { view.accessibilityIncrement() }
        XCTAssertEqual(view.zoomScale, 6)
        for _ in 0..<20 { view.accessibilityDecrement() }
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertEqual(view.contentOffset, .zero)
    }
}
