import UIKit
import XCTest
@testable import Luma

final class PTZTouchTests: XCTestCase {
    @MainActor
    func testTouchDownAndEveryReleaseEventAreSynchronousAndDeduplicated() async throws {
        for release in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
            let control = PTZTouchControl(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
            var events: [String] = []
            control.onPress = { events.append("press") }
            control.onRelease = { events.append("release") }
            control.sendActions(for: .touchDown)
            XCTAssertEqual(events, ["press"], "Press must dispatch synchronously, without a SwiftUI update or hold delay.")
            control.sendActions(for: .touchDown)
            XCTAssertEqual(events, ["press"])
            control.sendActions(for: release)
            XCTAssertEqual(events, ["press", "release"], "Release must dispatch on the same main-actor call stack.")
            control.sendActions(for: .touchCancel)
            control.sendActions(for: .touchUpInside)
            XCTAssertEqual(events, ["press", "release"])
            control.sendActions(for: .touchDown)
            control.sendActions(for: release)
            XCTAssertEqual(events, ["press", "release", "press", "release"])
        }
    }

    @MainActor
    func testDisablingAHeldControlImmediatelyReleasesItOnce() async throws {
        let control = PTZTouchControl(frame: .zero)
        var presses = 0
        var releases = 0
        control.onPress = { presses += 1 }
        control.onRelease = { releases += 1 }
        control.sendActions(for: .touchDown)
        control.isEnabled = false
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
        control.isEnabled = false
        control.sendActions(for: .touchCancel)
        XCTAssertEqual(releases, 1)
        control.sendActions(for: .touchDown)
        XCTAssertEqual(presses, 1, "Synthetic or stale events must not move a disabled control.")
        control.isEnabled = true
        control.sendActions(for: .touchDown)
        control.sendActions(for: .touchUpInside)
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 2)
    }

    @MainActor
    func testRemovingHeldControlFromWindowImmediatelyReleasesIt() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let host = UIViewController()
        window.rootViewController = host
        let control = PTZTouchControl(frame: CGRect(x: 20, y: 20, width: 60, height: 60))
        host.view.addSubview(control)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        XCTAssertNotNil(control.window)
        var releases = 0
        control.onPress = {}
        control.onRelease = { releases += 1 }
        control.sendActions(for: .touchDown)
        control.removeFromSuperview()
        XCTAssertNil(control.window)
        XCTAssertEqual(releases, 1)
        control.sendActions(for: .touchCancel)
        XCTAssertEqual(releases, 1)
    }

    @MainActor
    func testAccessibilityActivationUsesBoundedNudgeWithoutHolding() async throws {
        let control = PTZTouchControl(frame: .zero)
        var events: [String] = []
        control.onPress = { events.append("press") }
        control.onRelease = { events.append("release") }
        control.onActivate = { events.append("activate") }
        XCTAssertTrue(control.accessibilityActivate())
        XCTAssertEqual(events, ["activate"])
        control.sendActions(for: .touchCancel)
        XCTAssertEqual(events, ["activate"])
        control.isEnabled = false
        XCTAssertFalse(control.accessibilityActivate())
        XCTAssertEqual(events, ["activate"])
    }

    @MainActor
    func testSharedScrollViewsRestoreTheirOriginalDelayOnlyAfterLastControlLeaves() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let host = UIViewController()
        window.rootViewController = host
        let outer = UIScrollView(frame: window.bounds)
        let inner = UIScrollView(frame: outer.bounds)
        outer.delaysContentTouches = true
        inner.delaysContentTouches = false
        host.view.addSubview(outer)
        outer.addSubview(inner)
        let first = PTZTouchControl(frame: CGRect(x: 20, y: 20, width: 60, height: 60))
        let second = PTZTouchControl(frame: CGRect(x: 100, y: 20, width: 60, height: 60))
        inner.addSubview(first)
        inner.addSubview(second)
        window.isHidden = false
        defer {
            first.removeFromSuperview()
            second.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }
        XCTAssertNotNil(first.window)
        XCTAssertFalse(outer.delaysContentTouches)
        XCTAssertFalse(inner.delaysContentTouches)
        first.removeFromSuperview()
        XCTAssertFalse(outer.delaysContentTouches, "One remaining PTZ control still needs immediate delivery.")
        XCTAssertFalse(inner.delaysContentTouches)
        second.removeFromSuperview()
        XCTAssertTrue(outer.delaysContentTouches)
        XCTAssertFalse(inner.delaysContentTouches, "An original false value must stay false after cleanup.")
    }

    @MainActor
    func testDetachingARepresentedControlReleasesAndRestoresScrollPolicyOnce() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let host = UIViewController()
        window.rootViewController = host
        let scroll = UIScrollView(frame: window.bounds)
        scroll.delaysContentTouches = true
        host.view.addSubview(scroll)
        let control = PTZTouchControl(frame: CGRect(x: 20, y: 20, width: 60, height: 60))
        scroll.addSubview(control)
        window.isHidden = false
        defer { control.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
        var releases = 0
        control.onRelease = { releases += 1 }
        control.sendActions(for: .touchDown)
        XCTAssertFalse(scroll.delaysContentTouches)
        control.detach()
        XCTAssertEqual(releases, 1)
        XCTAssertTrue(scroll.delaysContentTouches)
        control.detach()
        control.sendActions(for: .touchUpOutside)
        XCTAssertEqual(releases, 1)
    }
}
