import SwiftUI

struct PTZControlsView: View {
    let controller: PTZController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Pan, tilt & zoom", systemImage: "move.3d")
                .font(.title2.weight(.semibold))
            Text("Hold a direction to move. Release to stop.")
                .font(.subheadline).foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        direction(.upLeft, symbol: "arrow.up.left", label: "Move up left")
                        direction(.up, symbol: "arrow.up", label: "Move up")
                        direction(.upRight, symbol: "arrow.up.right", label: "Move up right")
                    }
                    HStack(spacing: 12) {
                        direction(.left, symbol: "arrow.left", label: "Move left")
                        Button { controller.stop() } label: {
                            Image(systemName: "stop.fill").frame(width: 42, height: 42)
                                .foregroundStyle(LumaTheme.onAccent)
                        }
                        .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                        .accessibilityLabel(Text("Stop movement"))
                        .accessibilityIdentifier("ptz.stop")
                        direction(.right, symbol: "arrow.right", label: "Move right")
                    }
                    HStack(spacing: 12) {
                        direction(.downLeft, symbol: "arrow.down.left", label: "Move down left")
                        direction(.down, symbol: "arrow.down", label: "Move down")
                        direction(.downRight, symbol: "arrow.down.right", label: "Move down right")
                    }
                    HStack(spacing: 28) {
                        direction(.zoomOut, symbol: "minus.magnifyingglass", label: "Zoom out")
                        direction(.zoomIn, symbol: "plus.magnifyingglass", label: "Zoom in")
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
            }
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ptz.error")
            }
            Text("Each hold stops after two seconds. Press again to continue.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .onDisappear { controller.stop() }
    }

    private func direction(_ direction: PTZDirection, symbol: String, label: LocalizedStringKey) -> some View {
        Button {} label: {
            Image(systemName: symbol).font(.title3.weight(.semibold))
        }
        .buttonStyle(PTZHoldStyle { pressed in
            if pressed { controller.press(direction) }
            else { controller.stop() }
        })
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Activate to move a short distance."))
        .accessibilityAction { controller.nudge(direction) }
    }
}

private struct PTZHoldStyle: ButtonStyle {
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 60, height: 60)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}
