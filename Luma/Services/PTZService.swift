import Foundation

enum PTZDirection: CaseIterable, Equatable, Sendable {
    case up, down, left, right, upLeft, upRight, downLeft, downRight, zoomIn, zoomOut
}

struct PTZCommand: Equatable, Sendable {
    let pan: Int
    let tilt: Int
    let zoom: Int
    static let durationMilliseconds = 500
    static let stop = PTZCommand(pan: 0, tilt: 0, zoom: 0)

    init(pan: Int, tilt: Int, zoom: Int) {
        self.pan = min(100, max(-100, pan))
        self.tilt = min(100, max(-100, tilt))
        self.zoom = min(100, max(-100, zoom))
    }

    init(direction: PTZDirection) {
        let speed = 30
        switch direction {
        case .up: self.init(pan: 0, tilt: speed, zoom: 0)
        case .down: self.init(pan: 0, tilt: -speed, zoom: 0)
        case .left: self.init(pan: -speed, tilt: 0, zoom: 0)
        case .right: self.init(pan: speed, tilt: 0, zoom: 0)
        case .upLeft: self.init(pan: -speed, tilt: speed, zoom: 0)
        case .upRight: self.init(pan: speed, tilt: speed, zoom: 0)
        case .downLeft: self.init(pan: -speed, tilt: -speed, zoom: 0)
        case .downRight: self.init(pan: speed, tilt: -speed, zoom: 0)
        case .zoomIn: self.init(pan: 0, tilt: 0, zoom: speed)
        case .zoomOut: self.init(pan: 0, tilt: 0, zoom: -speed)
        }
    }

    var isStop: Bool { pan == 0 && tilt == 0 && zoom == 0 }
    var resource: String { isStop ? "continuous" : "momentary" }

    var xml: Data {
        // Vendor PTZ Service Specification 2.0, sections 4.8 and 4.9.
        // A lost connection cannot leave a momentary movement running indefinitely.
        let momentary = isStop ? "" : "<Momentary><duration>\(Self.durationMilliseconds)</duration></Momentary>"
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

    init(configuration: CameraConfiguration) throws {
        let camera = try configuration.validated()
        guard camera.ptzEnabled else { throw PTZError.disabled }
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
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
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

@MainActor
protocol PTZTransport {
    func send(_ command: PTZCommand) async throws
}

@MainActor
final class PTZService: PTZTransport {
    private let configuration: CameraConfiguration
    private let password: String
    private var session: URLSession?

    init(configuration: CameraConfiguration, password: String) {
        self.configuration = configuration
        self.password = password
    }

    deinit { session?.finishTasksAndInvalidate() }

    func send(_ command: PTZCommand) async throws {
        let endpoint: PTZEndpoint
        do { endpoint = try PTZEndpoint(configuration: configuration) }
        catch { throw PTZError.invalidSettings }
        if session == nil {
            let settings = URLSessionConfiguration.ephemeral
            settings.urlCredentialStorage = nil
            settings.urlCache = nil
            settings.httpCookieStorage = nil
            settings.httpShouldSetCookies = false
            settings.waitsForConnectivity = false
            settings.timeoutIntervalForRequest = 3
            settings.timeoutIntervalForResource = 5
            settings.httpMaximumConnectionsPerHost = 1
            let authentication = PTZAuthenticationDelegate(endpoint: endpoint, username: configuration.username, password: password)
            session = URLSession(configuration: settings, delegate: authentication, delegateQueue: nil)
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

private final class PTZAuthenticationDelegate: NSObject, URLSessionTaskDelegate {
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
    case disabled, invalidSettings, connectionFailed, permissionDenied, unsupported, invalidResponse, commandRejected
    var errorDescription: String? {
        switch self {
        case .disabled: String(localized: "Enable PTZ control in this camera's settings first.")
        case .invalidSettings: String(localized: "Check the PTZ control address, port, and channel.")
        case .connectionFailed: String(localized: "PTZ could not connect. Check the control port, local network access, and device account. HTTP requires Digest authentication; HTTPS requires a trusted certificate.")
        case .permissionDenied: String(localized: "The device rejected PTZ access. Check the device account and its PTZ permission.")
        case .unsupported: String(localized: "This device or channel does not support timed ISAPI PTZ control.")
        case .invalidResponse: String(localized: "The PTZ response was not valid. Check the control port and device settings.")
        case .commandRejected: String(localized: "The camera rejected this PTZ command. Check timed PTZ support, the control channel, and account permissions.")
        }
    }
}
