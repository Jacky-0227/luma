import SwiftUI

struct CameraEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let store: CameraStore
    let camera: CameraConfiguration?
    // A sheet owns one editing draft. Its route identity changes for another camera.
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var channel: Int
    @State private var quality: StreamQuality
    @State private var useTCP: Bool
    @State private var customPath: String
    @State private var controlPort: String
    @State private var controlUseHTTPS: Bool
    @State private var password = ""
    @State private var passwordLoaded = false
    @State private var showPassword = false
    @State private var message: InterfaceMessage?

    init(store: CameraStore, camera: CameraConfiguration?) {
        self.store = store
        self.camera = camera
        _name = State(initialValue: camera?.name ?? "")
        _host = State(initialValue: camera?.host ?? "")
        _port = State(initialValue: String(camera?.port ?? 554))
        _username = State(initialValue: camera?.username ?? "admin")
        _channel = State(initialValue: camera?.channel ?? 1)
        _quality = State(initialValue: camera?.defaultQuality ?? .sub)
        _useTCP = State(initialValue: camera?.useTCP ?? true)
        _customPath = State(initialValue: camera?.customPath ?? "")
        _controlPort = State(initialValue: String(camera?.controlPort ?? 80))
        _controlUseHTTPS = State(initialValue: camera?.controlUseHTTPS ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Front door"))
                        .accessibilityIdentifier("camera.name")
                    TextField("IP address or hostname", text: $host, prompt: Text("192.0.2.64"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("camera.host")
                } header: {
                    Text("CAMERA")
                } footer: {
                    Text("Use the camera or recorder address on your home network.")
                }
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("camera.username")
                    HStack {
                        Group {
                            if showPassword { TextField("Password", text: $password) }
                            else { SecureField("Password", text: $password) }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("camera.password")
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? Text("Hide password") : Text("Show password"))
                    }
                } header: {
                    Text("DEVICE ACCOUNT")
                } footer: {
                    Text("Use the device account, not your cloud account. Passwords stay in this iPhone’s Keychain.")
                }
                Section {
                    Stepper(value: $channel, in: 1...256) {
                        LabeledContent("Channel", value: channel.formatted())
                    }
                    Picker("Default quality", selection: $quality) {
                        ForEach(StreamQuality.allCases) { item in Text(item.title).tag(item) }
                    }
                } header: {
                    Text("LIVE VIEW")
                } footer: {
                    Text("For a single camera, use channel 1. For a recorder, choose its camera channel.")
                }
                Section {
                    Label("Camera controls are detected automatically.", systemImage: "viewfinder")
                        .accessibilityIdentifier("camera.ptz.automatic")
                    DisclosureGroup("Advanced control connection") {
                        LabeledContent("Control port") {
                            TextField("Control port", text: $controlPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Toggle("Use HTTPS for controls", isOn: $controlUseHTTPS)
                            .onChange(of: controlUseHTTPS) { _, secured in
                                if secured && controlPort == "80" { controlPort = "443" }
                                else if !secured && controlPort == "443" { controlPort = "80" }
                            }
                    }
                } header: {
                    Text("PTZ CAMERA")
                } footer: {
                    Text("Luma checks PTZ capabilities when you open live view. Detection does not move the camera. The control port is separate from the RTSP port.")
                }
                Section {
                    LabeledContent("RTSP port") {
                        TextField("RTSP port", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("camera.port")
                    }
                    Toggle("Use TCP", isOn: $useTCP)
                    TextField("Custom stream path (optional)", text: $customPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("ADVANCED")
                } footer: {
                    Text("Leave the path empty for Hikvision. A custom path is used as entered for both quality options.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background { LumaBackground() }
            .navigationTitle(camera == nil ? String(localized: "Add camera") : String(localized: "Edit camera"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("camera.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!passwordLoaded)
                        .accessibilityIdentifier("camera.save")
                }
            }
            .lumaAlert($message)
            .task {
                guard !passwordLoaded else { return }
                do {
                    if let camera { password = try store.password(for: camera) }
                    passwordLoaded = true
                } catch CredentialError.missingPassword {
                    passwordLoaded = true
                } catch CredentialError.invalidData {
                    passwordLoaded = true
                } catch { message = InterfaceMessage(text: error.localizedDescription) }
            }
        }
    }

    private func save() {
        guard let portValue = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = InterfaceMessage(text: String(localized: "Enter a port number between 1 and 65535."))
            return
        }
        guard let controlPortValue = Int(controlPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = InterfaceMessage(text: String(localized: "Enter a control port between 1 and 65535."))
            return
        }
        let draft = CameraConfiguration(
            id: camera?.id ?? UUID(), name: name, host: host, port: portValue,
            username: username, channel: channel, defaultQuality: quality,
            useTCP: useTCP, customPath: customPath,
            ptzEnabled: camera?.ptzEnabled ?? false, controlPort: controlPortValue,
            controlUseHTTPS: controlUseHTTPS, ptzChannel: camera?.ptzChannel ?? channel
        )
        do {
            try store.save(draft, password: password)
            dismiss()
        } catch { message = InterfaceMessage(text: error.localizedDescription) }
    }
}
