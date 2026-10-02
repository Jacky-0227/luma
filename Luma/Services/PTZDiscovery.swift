import CryptoKit
import Foundation

struct PTZCapabilities: Equatable, Sendable {
    let channel: Int
    let panTilt: Bool
    let zoom: Bool
}

enum PTZDiscoveryResult: Equatable, Sendable {
    case available(PTZCapabilities)
    case unavailable
    case unknown
}

enum PTZDiscoveryResource: Equatable, Sendable {
    case channels
    case capabilities(Int)

    func request(endpoint: PTZEndpoint) throws -> URLRequest {
        let path: String
        switch self {
        case .channels: path = "/ISAPI/PTZCtrl/channels"
        case .capabilities(let channel):
            guard (1...999).contains(channel) else { throw PTZError.invalidSettings }
            path = "/ISAPI/PTZCtrl/channels/\(channel)/capabilities"
        }
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        guard let url = URL(string: "\(endpoint.scheme)://\(host):\(endpoint.port)\(path)") else {
            throw PTZError.invalidSettings
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        return request
    }
}

@MainActor
protocol PTZDiscoveryTransport {
    func get(_ resource: PTZDiscoveryResource) async throws -> Data
}

/// Discovery only uses GET. Authentication, redirects and TLS follow the same
/// exact-endpoint policy as control requests; no movement is used as a probe.
@MainActor
final class ISAPIPTZDiscoveryTransport: PTZDiscoveryTransport {
    private let endpoint: PTZEndpoint
    private let session: URLSession

    init(configuration: CameraConfiguration, password: String) throws {
        endpoint = try PTZEndpoint(configuration: configuration, requireEnabled: false)
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

    deinit { session.invalidateAndCancel() }

    func get(_ resource: PTZDiscoveryResource) async throws -> Data {
        let (data, response) = try await session.data(for: resource.request(endpoint: endpoint))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw PTZError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw PTZError.permissionDenied }
        if [404, 405, 501].contains(response.statusCode) { throw PTZError.unsupported }
        guard (200...299).contains(response.statusCode), data.count <= 131_072 else { throw PTZError.invalidResponse }
        return data
    }
}

enum PTZCapabilityDocument {
    struct Channel: Equatable, Sendable {
        let id: Int
        let videoInputID: Int?
        let enabled: Bool
    }

    static func channels(_ data: Data) throws -> [Channel] {
        let root = try PTZXMLNode.parse(data)
        guard root.name == "PTZChannelList" else { throw PTZError.invalidResponse }
        var channels: [Channel] = []
        for child in root.children where child.name == "PTZChannel" {
            guard let text = child.child("id")?.text, let id = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...999).contains(id), !channels.contains(where: { $0.id == id }) else { throw PTZError.invalidResponse }
            var videoInputID: Int?
            if let input = child.child("videoInputID")?.text {
                guard let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)), (1...999).contains(value)
                else { throw PTZError.invalidResponse }
                videoInputID = value
            }
            let enabledText = child.child("enabled")?.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let enabledText, !["true", "false", "1", "0"].contains(enabledText) { throw PTZError.invalidResponse }
            channels.append(Channel(id: id, videoInputID: videoInputID, enabled: enabledText != "false" && enabledText != "0"))
        }
        return channels
    }

    /// Hikvision's documented root is spelled PTZChanelCap (one n).
    /// Missing timed movement spaces do not prove the camera is physically fixed.
    static func capabilities(_ data: Data, channel: Int) throws -> PTZDiscoveryResult {
        let root = try PTZXMLNode.parse(data)
        guard ["PTZChanelCap", "PTZChannelCap"].contains(root.name) else { throw PTZError.invalidResponse }
        let panTilt = try hasRange(root.child("MomentaryPanTiltSpace"), axes: ["XRange", "YRange"])
        let zoom = try hasRange(root.child("MomentaryZoomSpace"), axes: ["ZRange"])
        guard panTilt || zoom else { return .unavailable }
        return .available(PTZCapabilities(channel: channel, panTilt: panTilt, zoom: zoom))
    }

    private static func hasRange(_ space: PTZXMLNode?, axes: [String]) throws -> Bool {
        guard let space else { return false }
        var enabled = true
        for axis in axes {
            guard let range = space.child(axis),
                  let lowText = range.child("Min")?.text, let highText = range.child("Max")?.text,
                  let low = Double(lowText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let high = Double(highText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  low.isFinite, high.isFinite, high >= low else { throw PTZError.invalidResponse }
            enabled = enabled && high > low
        }
        return enabled
    }
}

@MainActor
enum PTZCapabilityDetector {
    static func detect(configuration: CameraConfiguration, transport: any PTZDiscoveryTransport) async throws -> PTZDiscoveryResult {
        // Preserve an explicitly configured legacy control channel. New entries
        // prefer their video channel, so an NVR never controls a different camera.
        var channel = configuration.ptzEnabled ? configuration.ptzChannel : configuration.channel
        do {
            let data = try await transport.get(.channels)
            let channels = try PTZCapabilityDocument.channels(data)
            try Task.checkCancellation()
            if channels.isEmpty { return .unavailable }
            // The vendor schema explicitly links control IDs to video inputs.
            // Never assume equal IDs when a device supplies that mapping.
            let mapped = channels.filter { $0.videoInputID == configuration.channel }
            let candidate: PTZCapabilityDocument.Channel?
            if mapped.count == 1 { candidate = mapped[0] }
            else if !mapped.isEmpty { return .unknown }
            else if let matching = channels.first(where: { $0.id == channel && $0.videoInputID == nil }) { candidate = matching }
            else if configuration.channel == 1, channels.count == 1, channels[0].videoInputID == nil { candidate = channels[0] }
            else { candidate = nil }
            guard let candidate else { return .unknown }
            guard candidate.enabled else { return .unavailable }
            channel = candidate.id
        } catch PTZError.unsupported {
            // Some firmware exposes capabilities without the collection route.
            // Probe only the matching channel; never scan or guess NVR channels.
        }
        let data = try await transport.get(.capabilities(channel))
        try Task.checkCancellation()
        return try PTZCapabilityDocument.capabilities(data, channel: channel)
    }
}

/// Process-memory cache and one in-flight read per endpoint/account/channel.
/// Shared reads finish within the HTTP deadline even if a view disappears;
/// cancelled waiters discard the result, and rapid reopenings join the same read.
@MainActor
final class PTZDiscovery {
    static let shared = PTZDiscovery()
    typealias Factory = @MainActor (CameraConfiguration, String) throws -> any PTZDiscoveryTransport
    private struct Key: Hashable {
        let host: String
        let port: Int
        let https: Bool
        let username: String
        let passwordHash: Data
        let videoChannel: Int
        let legacyChannel: Int?
    }
    private struct Entry {
        let result: PTZDiscoveryResult
        let expires: Date
    }
    private let factory: Factory
    private var cache: [Key: Entry] = [:]
    private var pending: [Key: Task<PTZDiscoveryResult, Never>] = [:]

    init(factory: @escaping Factory = { try ISAPIPTZDiscoveryTransport(configuration: $0, password: $1) }) {
        self.factory = factory
    }

    func detect(configuration: CameraConfiguration, password: String) async throws -> PTZDiscoveryResult {
        try Task.checkCancellation()
        let camera = try configuration.validated()
        let key = Key(host: camera.host.lowercased(), port: camera.controlPort, https: camera.controlUseHTTPS,
                      username: camera.username, passwordHash: Data(SHA256.hash(data: Data(password.utf8))),
                      videoChannel: camera.channel, legacyChannel: camera.ptzEnabled ? camera.ptzChannel : nil)
        if let entry = cache[key], entry.expires > Date() { return entry.result }
        let task: Task<PTZDiscoveryResult, Never>
        if let existing = pending[key] { task = existing }
        else {
            let factory = self.factory
            task = Task { @MainActor in
                let result: PTZDiscoveryResult
                do {
                    result = try await PTZCapabilityDetector.detect(configuration: camera, transport: factory(camera, password))
                } catch { result = .unknown }
                self.pending[key] = nil
                if self.cache.count >= 64 { self.cache.removeAll() }
                self.cache[key] = Entry(result: result, expires: Date().addingTimeInterval(result == .unknown ? 15 : 300))
                return result
            }
            pending[key] = task
        }
        let result = await task.value
        try Task.checkCancellation()
        return result
    }
}

private final class PTZXMLNode: NSObject, XMLParserDelegate {
    let name: String
    var text = ""
    var children: [PTZXMLNode] = []
    private var stack: [PTZXMLNode] = []
    private var count = 0

    init(name: String) { self.name = name }
    func child(_ name: String) -> PTZXMLNode? { children.first { $0.name == name } }

    static func parse(_ data: Data) throws -> PTZXMLNode {
        guard !data.isEmpty, data.count <= 131_072,
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw PTZError.invalidResponse }
        let delegate = PTZXMLNode(name: "document")
        delegate.stack = [delegate]
        defer { delegate.stack = [] }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.children.count == 1, delegate.stack.count == 1,
              let root = delegate.children.first else { throw PTZError.invalidResponse }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 32, count <= 4096 else { parser.abortParsing(); return }
        let node = PTZXMLNode(name: elementName)
        stack.last?.children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text.append(string) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }
}
