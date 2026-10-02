import Foundation

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

    var xml: Data {
        // Vendor PTZ Service Specification 2.0, sections 4.8 and 4.9.
        // A lost connection cannot leave a momentary movement running indefinitely.
        let momentary = mode == .momentary ? "<Momentary><duration>\(Self.durationMilliseconds)</duration></Momentary>" : ""
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <PTZData version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><pan>\(pan)</pan><tilt>\(tilt)</tilt><zoom>\(zoom)</zoom>\(momentary)</PTZData>
        """.utf8)
    }
}

struct PTZEndpoint: Sendable {
    let host: String
    let port: Int
    let scheme: String
    let channel: Int

    init(configuration: CameraConfiguration, requireEnabled: Bool = true) throws {
        let camera = try configuration.validated()
        guard !requireEnabled || camera.ptzEnabled else { throw PTZError.disabled }
        host = camera.host.lowercased()
        port = camera.controlPort
        scheme = camera.controlUseHTTPS ? "https" : "http"
        channel = camera.ptzChannel
    }

    func request(for command: PTZCommand) throws -> URLRequest {
        let address = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "\(scheme)://\(address):\(port)/ISAPI/PTZCtrl/channels/\(channel)/\(command.resource)") else {
            throw PTZError.invalidSettings
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: PTZRequestPolicy.timeout(for: command))
        request.httpMethod = "PUT"
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.httpBody = command.xml
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
    // A move must not occupy the FIFO for the former five-second resource
    // deadline. Failure still requires Stop because acceptance is uncertain.
    static func timeout(for command: PTZCommand) -> TimeInterval { command.isStop ? 2 : 1.5 }

    static func sessionConfiguration(for command: PTZCommand) -> URLSessionConfiguration {
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.waitsForConnectivity = false
        settings.timeoutIntervalForRequest = timeout(for: command)
        settings.timeoutIntervalForResource = timeout(for: command)
        settings.httpMaximumConnectionsPerHost = 1
        return settings
    }
}

@MainActor
protocol PTZTransport {
    func send(_ command: PTZCommand) async throws
}

@MainActor
final class PTZService: PTZTransport {
    private let configuration: CameraConfiguration
    private let password: String
    private var moveSession: URLSession?
    private var stopSession: URLSession?

    init(configuration: CameraConfiguration, password: String) {
        self.configuration = configuration
        self.password = password
    }

    deinit {
        moveSession?.finishTasksAndInvalidate()
        stopSession?.finishTasksAndInvalidate()
    }

    func send(_ command: PTZCommand) async throws {
        let endpoint: PTZEndpoint
        do { endpoint = try PTZEndpoint(configuration: configuration) }
        catch { throw PTZError.invalidSettings }
        var session = command.isStop ? stopSession : moveSession
        if session == nil {
            let settings = PTZRequestPolicy.sessionConfiguration(for: command)
            let authentication = PTZAuthenticationDelegate(endpoint: endpoint, username: configuration.username, password: password)
            session = URLSession(configuration: settings, delegate: authentication, delegateQueue: nil)
            if command.isStop { stopSession = session }
            else { moveSession = session }
        }
        guard let session else { throw PTZError.connectionFailed }
        do {
            let (data, response) = try await session.data(for: endpoint.request(for: command))
            guard let response = response as? HTTPURLResponse else { throw PTZError.invalidResponse }
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
        completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .none))
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
        guard (200...299).contains(statusCode), body.count <= 65_536 else { throw PTZError.invalidResponse }
        let delegate = PTZStatusParser()
        let parser = XMLParser(data: body)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.root == "ResponseStatus", delegate.codes.count == 1,
              let code = Int(delegate.codes[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PTZError.invalidResponse
        }
        guard code == 0 || code == 1 else { throw PTZError.commandRejected }
    }
}

private final class PTZStatusParser: NSObject, XMLParserDelegate {
    var root: String?
    var codes: [String] = []
    private var capturedCode: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if root == nil { root = elementName }
        if elementName == "statusCode" { capturedCode = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturedCode != nil { capturedCode?.append(string) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "statusCode", let code = capturedCode {
            codes.append(code)
            capturedCode = nil
        }
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
