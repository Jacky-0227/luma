import SwiftUI

struct SettingsView: View {
    let store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        Image("BrandMark").resizable().scaledToFit()
                            .frame(width: 84, height: 84)
                            .clipShape(.rect(cornerRadius: 22))
                            .accessibilityHidden(true)
                        Text("Luma").font(.largeTitle.weight(.semibold)).fontDesign(.rounded)
                        Text("Home. Within sight.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .listRowBackground(Color.clear)
                }
                Section("EXPERIENCE") {
                    LabeledContent("Language", value: String(localized: "Follows iPhone settings"))
                    Button("Open language & privacy settings", systemImage: "arrow.up.forward.app") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Text("繁體中文 · 简体中文 · English").font(.footnote).foregroundStyle(.secondary)
                }
                Section("PRIVATE BY DESIGN") {
                    Label("Camera video connects directly to your device.", systemImage: "network")
                    Label("Passwords are stored in the iPhone Keychain.", systemImage: "key")
                    Label("No accounts, advertising or analytics in Luma.", systemImage: "hand.raised")
                }
                Section {
                    NavigationLink("Configuration backup") { ConfigurationBackupView(store: store) }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                    NavigationLink("Open-source software") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("VideoLAN · VLCKit").font(.title2.weight(.semibold))
                                Text("Luma uses MobileVLCKit to play camera streams.")
                                Text("https://code.videolan.org/videolan/VLCKit")
                                    .font(.footnote).textSelection(.enabled)
                                Text("MobileVLCKit is distributed under LGPL 2.1 or later. See the project’s ThirdPartyNotices for source and relinking information.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.padding(24)
                        }
                        .navigationTitle("Open-source software")
                    }
                } header: {
                    Text("ABOUT")
                }
            }
            .scrollContentBackground(.hidden)
            .background { LumaBackground() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
