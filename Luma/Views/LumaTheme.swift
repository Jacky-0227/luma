import SwiftUI

enum LumaTheme {
    static let accent = Color("AccentColor")
    // Accent is deep teal in light mode and bright cyan in dark mode.
    static let onAccent = Color(uiColor: .systemBackground)
    static let cornerRadius: CGFloat = 28
}

struct LumaBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [LumaTheme.accent.opacity(colorScheme == .dark ? 0.13 : 0.08), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 24

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: radius))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: radius))
        }
    }
}

struct InterfaceMessage: Identifiable {
    let id = UUID()
    let text: String
}

extension View {
    func lumaAlert(_ message: Binding<InterfaceMessage?>) -> some View {
        alert("Something needs attention", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        ), presenting: message.wrappedValue) { _ in
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: { Text($0.text) }
    }
}
