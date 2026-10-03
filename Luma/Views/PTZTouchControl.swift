import SwiftUI
import UIKit

/// Touch events go directly to the controller, without a SwiftUI render pass
/// or the enclosing scroll view's initial content-touch delay.
@MainActor
final class PTZTouchControl: UIButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onActivate: (() -> Void)?
    private var hasActiveHold = false
    private var scrollIDs: [ObjectIdentifier] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(press), for: .touchDown)
        addTarget(self, action: #selector(releaseHold),
                  for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { if !isEnabled { releaseHold() } }
    }

    @objc private func press() {
        guard isEnabled, !hasActiveHold else { return }
        hasActiveHold = true
        onPress?()
    }

    @objc func releaseHold() {
        guard hasActiveHold else { return }
        hasActiveHold = false
        onRelease?()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, let onActivate else { return false }
        releaseHold()
        onActivate()
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScrollTouchDelivery()
        if window == nil { releaseHold() }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateScrollTouchDelivery()
        if superview == nil { releaseHold() }
    }

    func detach() {
        releaseHold()
        for id in scrollIDs { ScrollTouchDelivery.release(id, owner: self) }
        scrollIDs.removeAll()
    }

    private func updateScrollTouchDelivery() {
        var ancestors: [UIScrollView] = []
        if window != nil {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { ancestors.append(scroll) }
                ancestor = view.superview
            }
        }
        let nextIDs = ancestors.map(ObjectIdentifier.init)
        for id in scrollIDs where !nextIDs.contains(id) {
            ScrollTouchDelivery.release(id, owner: self)
        }
        for scroll in ancestors where !scrollIDs.contains(ObjectIdentifier(scroll)) {
            ScrollTouchDelivery.acquire(scroll, owner: self)
        }
        scrollIDs = nextIDs
    }
}

/// Several PTZ buttons share the same scroll view. Restore its original setting
/// only when the last button leaves; never modify the app-wide appearance proxy.
@MainActor
private enum ScrollTouchDelivery {
    @MainActor
    final class Entry {
        weak var scroll: UIScrollView?
        let originalDelay: Bool
        let owners = NSHashTable<PTZTouchControl>.weakObjects()

        init(_ scroll: UIScrollView) {
            self.scroll = scroll
            originalDelay = scroll.delaysContentTouches
        }
    }

    static var entries: [ObjectIdentifier: Entry] = [:]

    static func acquire(_ scroll: UIScrollView, owner: PTZTouchControl) {
        entries = entries.filter { $0.value.scroll != nil }
        let id = ObjectIdentifier(scroll)
        let entry = entries[id] ?? Entry(scroll)
        entry.owners.add(owner)
        entries[id] = entry
        scroll.delaysContentTouches = false
    }

    static func release(_ id: ObjectIdentifier, owner: PTZTouchControl) {
        guard let entry = entries[id] else { return }
        entry.owners.remove(owner)
        if entry.owners.allObjects.isEmpty {
            entry.scroll?.delaysContentTouches = entry.originalDelay
            entries.removeValue(forKey: id)
        }
    }
}

struct PTZHoldButton: UIViewRepresentable {
    let controller: PTZController
    let direction: PTZDirection
    let symbol: String
    let label: String
    let isEnabled: Bool

    @MainActor
    final class Coordinator {
        var finishHold: (() -> Void)?
        func release() {
            let finish = finishHold
            finishHold = nil
            finish?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PTZTouchControl {
        let button = PTZTouchControl(frame: .zero)
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 20, weight: .semibold)
        button.configuration = configuration
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: PTZTouchControl, context: Context) {
        let coordinator = context.coordinator
        button.configuration?.image = UIImage(systemName: symbol)
        button.accessibilityLabel = label
        button.accessibilityHint = String(localized: "Activate to move a short distance.")
        button.onPress = {
            coordinator.release()
            if let token = controller.press(direction) {
                coordinator.finishHold = { controller.release(token: token) }
            }
        }
        button.onRelease = { coordinator.release() }
        button.onActivate = { controller.nudge(direction) }
        button.isEnabled = isEnabled
    }

    static func dismantleUIView(_ button: PTZTouchControl, coordinator: Coordinator) {
        button.detach()
        coordinator.release()
        button.onPress = nil
        button.onRelease = nil
        button.onActivate = nil
    }
}
