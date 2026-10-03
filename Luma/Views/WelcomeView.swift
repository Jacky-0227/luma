import SwiftUI

/// Branding belongs to the first launch, while daily screens use section names.
struct WelcomeView: View {
    let continueToCameras: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .clipShape(.rect(cornerRadius: 40))
                    .accessibilityHidden(true)
                Text("Luma")
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.rounded)
                VStack(spacing: 14) {
                    Text("Home. Within sight.")
                        .font(.title.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("A quieter way to keep an eye on home.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                Label("Direct connection. Yours alone.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 56)
        }
        .background { LumaBackground() }
        .safeAreaInset(edge: .bottom) {
            Button(action: continueToCameras) {
                Text("Get started").frame(maxWidth: .infinity)
                    .foregroundStyle(LumaTheme.onAccent)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("welcome.continue")
            .frame(maxWidth: 560)
            .padding(24)
        }
    }
}
