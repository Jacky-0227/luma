import Foundation
import OSLog

enum PTZDirection: CaseIterable, Equatable, Sendable {
    case up, down, left, right, upLeft, upRight, downLeft, downRight, zoomIn, zoomOut
}

struct PTZCommand: Equatable, Sendable {
    let pan: Int
    let tilt: Int
    let zoom: Int
    let mode: PTZMovementMode
    static let durationMilliseconds = 500
    static let stop = PTZCommand(pan: 0, tilt: 0, zoom: 0, mode: .continuous)

    init(pan: Int, tilt: Int, zoom: Int, mode: PTZMovementMode = .momentary) {
        self.pan = min(100, max(-100, pan))
        self.tilt = min(100, max(-100, tilt))
        self.zoom = min(100, max(-100, zoom))
        self.mode = mode
    }

    init(direction: PTZDirection, mode: PTZMovementMode = .momentary) {
        let speed = 30
        switch direction {
        case .up: self.init(pan: 0, tilt: speed, zoom: 0, mode: mode)
        case .down: self.init(pan: 0, tilt: -speed, zoom: 0, mode: mode)
        case .left: self.init(pan: -speed, tilt: 0, zoom: 0, mode: mode)
        case .right: self.init(pan: speed, tilt: 0, zoom: 0, mode: mode)
        case .upLeft: self.init(pan: -speed, tilt: speed, zoom: 0, mode: mode)
        case .upRight: self.init(pan: speed, tilt: speed, zoom: 0, mode: mode)
        case .downLeft: self.init(pan: -speed, tilt: -speed, zoom: 0, mode: mode)
        case .downRight: self.init(pan: speed, tilt: -speed, zoom: 0, mode: mode)
        case .zoomIn: self.init(pan: 0, tilt: 0, zoom: speed, mode: mode)
        case .zoomOut: self.init(pan: 0, tilt: 0, zoom: -speed, mode: mode)
        }
    }

    var isStop: Bool { pan == 0 && tilt == 0 && zoom == 0 }
    var resource: String { mode == .continuous ? "continuous" : "momentary" }

    static func stop(mode: PTZMovementMode) -> PTZCommand {
        PTZCommand(pan: 0, tilt: 0, zoom: 0, mode: mode)
    }

    var xml: Data { xml(for: .isapi) }

    func xml(for family: PTZAPIFamily) -> Data {
        // Vendor PTZ Service Specification 2.0, sections 4.8 and 4.9.
        // A lost connection cannot leave a momentary movement running indefinitely.
        let momentary = mode == .momentary ? "<Momentary><duration>\(Self.durationMilliseconds)</duration></Momentary>" : ""
        let version = family == .legacy ? "1.0" : "2.0"
        let namespace = family == .legacy ? "http://www.hikvision.com/ver10/XMLSchema" : "http://www.isapi.org/ver20/XMLSchema"
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <PTZData version="\(version)" xmlns="\(namespace)"><pan>\(pan)</pan><tilt>\(tilt)</tilt><zoom>\(zoom)</zoom>\(momentary)</PTZData>
        """.utf8)
    }
}

struct PTZEndpoint: Sendable {
    let host: String
    let port: Int
    let scheme: String
    let channel: Int
    let apiFamily: PTZAPIFamily

    init(configuration: CameraConfiguration, requireEnabled: Bool = true, apiFamily: PTZAPIFamily = .isapi) throws {
        let camera = try configuration.validated()
        guard !requireEnabled || camera.ptzEnabled else { throw PTZError.disabled }
        host = camera.host.lowercased()
        port = camera.controlPort
        scheme = camera.controlUseHTTPS ? "https" : "http"
        channel = camera.ptzChannel
        self.apiFamily = apiFamily
    }

    func request(for command: PTZCommand) throws -> URLRequest {
        let address = host.contains(":") ? "[\(host)]" : host
        let prefix = apiFamily == .legacy ? "" : "/ISAPI"
        guard let url = URL(string: "\(scheme)://\(address):\(port)\(prefix)/PTZCtrl/channels/\(channel)/\(command.resource)") else {
            throw PTZError.invalidSettings
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: PTZRequestPolicy.timeout(for: command))
        request.httpMethod = "PUT"
        request.networkServiceType = .responsiveData
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.httpBody = command.xml(for: apiFamily)
        return request
    }

    func statusRequest() throws -> URLRequest {
        let address = host.contains(":") ? "[\(host)]" : host
        let prefix = apiFamily == .legacy ? "" : "/ISAPI"
        guard let url = URL(string: "\(scheme)://\(address):\(port)\(prefix)/PTZCtrl/channels/\(channel)/status") else {
            throw PTZError.invalidSettings
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        request.httpMethod = "GET"
        request.networkServiceType = .responsiveData
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        return request
    }

    func permitsCredentials(host: String, port: Int, scheme: String?, method: String, isProxy: Bool) -> Bool {
        let challengeHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !isProxy, challengeHost == self.host, port == self.port, scheme?.lowercased() == self.scheme else { return false }
        return method == NSURLAuthenticationMethodHTTPDigest
            || (self.scheme == "https" && method == NSURLAuthenticationMethodHTTPBasic)
    }
}

enum PTZRequestPolicy {
    // Both lanes share a session and its two-second total resource deadline.
    // The movement request also has a shorter per-request inactivity timeout.
    static func timeout(for command: PTZCommand) -> TimeInterval { command.isStop ? 2 : 1.5 }

    static func sessionConfiguration(for command: PTZCommand) -> URLSessionConfiguration {
        let settings = URLSessionConfiguration.ephemeral
        // Keep ephemeral's private RAM-only credential store, destroyed with
        // this session. It lets both lanes reuse authentication without Keychain.
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.waitsForConnectivity = false
        settings.timeoutIntervalForRequest = 2
        settings.timeoutIntervalForResource = 2
        settings.httpMaximumConnectionsPerHost = 2
        return settings
    }
}

@MainActor
protocol PTZTransport {
    func send(_ command: PTZCommand) async throws
    func prepare() async
}

extension PTZTransport {
    func prepare() async {}
}

@MainActor
final class PTZService: PTZTransport {
    private let configuration: CameraConfiguration
    private let password: String
    private let apiFamily: PTZAPIFamily
    private var session: URLSession?
    private var preparation: (id: UUID, task: Task<Void, Never>)?
    private var activeCommands = 0
    private static let performanceLog = Logger(subsystem: "app.luma.viewer", category: "PTZ")

    init(configuration: CameraConfiguration, password: String, apiFamily: PTZAPIFamily = .isapi) {
        self.configuration = configuration
        self.password = password
        self.apiFamily = apiFamily
    }

    deinit {
        preparation?.task.cancel()
        session?.finishTasksAndInvalidate()
    }

    private func connection(for endpoint: PTZEndpoint) -> URLSession {
        if let session { return session }
        let settings = PTZRequestPolicy.sessionConfiguration(for: .stop)
        let authentication = PTZAuthenticationDelegate(endpoint: endpoint, username: configuration.username, password: password)
        let next = URLSession(configuration: settings, delegate: authentication, delegateQueue: nil)
        session = next
        return next
    }

    /// A read-only status query establishes Digest authentication and keep-alive
    /// before touch-down. It never sends movement/Stop and never gates controls.
    /// Unsupported status endpoints do not override discovery's capability result.
    func prepare() async {
        guard activeCommands == 0, preparation == nil, !Task.isCancelled,
              let endpoint = try? PTZEndpoint(configuration: configuration, apiFamily: apiFamily),
              let request = try? endpoint.statusRequest() else { return }
        let session = connection(for: endpoint)
        let id = UUID()
        let task = Task { @MainActor in
            do { _ = try await session.data(for: request) }
            catch { /* Optional readiness, never a reason to disable working controls. */ }
        }
        preparation = (id, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if preparation?.id == id { preparation = nil }
    }

    func send(_ command: PTZCommand) async throws {
        let endpoint: PTZEndpoint
        do { endpoint = try PTZEndpoint(configuration: configuration, apiFamily: apiFamily) }
        catch { throw PTZError.invalidSettings }
        // A stalled status GET must never occupy a lane needed by touch-down or Stop.
        preparation?.task.cancel()
        preparation = nil
        activeCommands += 1
        defer { activeCommands -= 1 }
        let session = connection(for: endpoint)
        let started = ContinuousClock.now
        let phase = command.isStop ? "stop" : "move"
        do {
            let (data, response) = try await session.data(for: endpoint.request(for: command))
            guard let response = response as? HTTPURLResponse else { throw PTZError.invalidResponse }
            let elapsed = started.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            // Only phase/status/duration; never addresses, credentials or device XML.
            Self.performanceLog.notice("phase=\(phase, privacy: .public) http=\(response.statusCode) elapsed_ms=\(milliseconds)")
            try PTZResponse.validate(statusCode: response.statusCode, body: data)
        } catch let error as PTZError {
            throw error
        } catch {
            // URLSession and device responses may contain identifiers; never expose their raw descriptions.
            throw PTZError.connectionFailed
        }
    }
}

final class PTZAuthenticationDelegate: NSObject, URLSessionTaskDelegate {
    private let endpoint: PTZEndpoint
    private let username: String
    private let password: String

    init(endpoint: PTZEndpoint, username: String, password: String) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Use normal platform certificate and hostname validation, including on a LAN.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount == 0,
              endpoint.permitsCredentials(host: space.host, port: space.port, scheme: space.protocol,
                                          method: space.authenticationMethod, isProxy: space.isProxy()) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PTZResponse {
    static func validate(statusCode: Int, body: Data) throws {
        if statusCode == 401 || statusCode == 403 { throw PTZError.permissionDenied }
        if [404, 405, 501].contains(statusCode) { throw PTZError.unsupported }
        guard body.count <= 65_536 else { throw PTZError.invalidResponse }
        let result = try PTZResponseDocument.validate(body)
        guard (200...299).contains(statusCode), result == .success else { throw PTZError.invalidResponse }
    }
}

enum PTZError: LocalizedError {
    case disabled, invalidSettings, connectionFailed, permissionDenied, unsupported, invalidResponse, commandRejected, stopUnconfirmed
    var errorDescription: String? {
        switch self {
        case .disabled: String(localized: "Enable PTZ control in this camera's settings first.")
        case .invalidSettings: String(localized: "Check the PTZ control address, port, and channel.")
        case .connectionFailed: String(localized: "PTZ could not connect. Check the control port, local network access, and device account. HTTP requires Digest authentication; HTTPS requires a trusted certificate.")
        case .permissionDenied: String(localized: "The device rejected PTZ access. Check the device account and its PTZ permission.")
        case .unsupported: String(localized: "This device or channel does not support this ISAPI PTZ command.")
        case .invalidResponse: String(localized: "The PTZ response was not valid. Check the control port and device settings.")
        case .commandRejected: String(localized: "The camera rejected this PTZ command. Check PTZ support, the control channel, and account permissions.")
        case .stopUnconfirmed: String(localized: "The camera has not confirmed stopping. Tap Stop to retry before moving again.")
        }
    }
}
