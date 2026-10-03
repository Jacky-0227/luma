import CryptoKit
import Foundation

enum PTZMovementMode: Equatable, Sendable {
    case momentary
    case continuous
}

/// The original IPMD protocol predates the /ISAPI prefix. Detection and control
/// must use the same API family; a successful legacy read cannot prove ISAPI works.
enum PTZAPIFamily: Equatable, Sendable {
    case isapi
    case legacy
}

struct PTZCapabilities: Equatable, Sendable {
    let channel: Int
    let panMode: PTZMovementMode?
    let tiltMode: PTZMovementMode?
    let zoomMode: PTZMovementMode?
    let supportsContinuousStop: Bool
    let apiFamily: PTZAPIFamily

    var panTilt: Bool { panMode != nil || tiltMode != nil }
    var zoom: Bool { zoomMode != nil }

    init(channel: Int, panMode: PTZMovementMode?, tiltMode: PTZMovementMode?,
         zoomMode: PTZMovementMode?, supportsContinuousStop: Bool = true, apiFamily: PTZAPIFamily = .isapi) {
        self.channel = channel
        self.panMode = panMode
        self.tiltMode = tiltMode
        self.zoomMode = zoomMode
        self.supportsContinuousStop = supportsContinuousStop
        self.apiFamily = apiFamily
    }

    /// Existing deterministic UI fixtures describe timed movement on every axis.
    init(channel: Int, panTilt: Bool, zoom: Bool, apiFamily: PTZAPIFamily = .isapi) {
        self.init(channel: channel, panMode: panTilt ? .momentary : nil,
                  tiltMode: panTilt ? .momentary : nil, zoomMode: zoom ? .momentary : nil, apiFamily: apiFamily)
    }
}

enum PTZDiscoveryResult: Equatable, Sendable {
    case available(PTZCapabilities)
    case unavailable
    case unsupported
    case unknown

    var cacheDuration: TimeInterval {
        if case .available = self { return 300 }
        return 15
    }
}

enum PTZDiscoveryResource: Equatable, Sendable {
    case channels
    case capabilities(Int)
    case configuration(Int)
    case legacyChannels
    case legacyCapabilities(Int)
    case legacyConfiguration(Int)

    func inFamily(_ family: PTZAPIFamily) -> Self {
        guard family == .legacy else { return self }
        switch self {
        case .channels: return .legacyChannels
        case .capabilities(let channel): return .legacyCapabilities(channel)
        case .configuration(let channel): return .legacyConfiguration(channel)
        default: return self
        }
    }

    func request(endpoint: PTZEndpoint) throws -> URLRequest {
        let path: String
        switch self {
        case .channels: path = "/ISAPI/PTZCtrl/channels"
        case .capabilities(let channel):
            guard (1...999).contains(channel) else { throw PTZError.invalidSettings }
            path = "/ISAPI/PTZCtrl/channels/\(channel)/capabilities"
        case .configuration(let channel):
            guard (1...999).contains(channel) else { throw PTZError.invalidSettings }
            path = "/ISAPI/PTZCtrl/channels/\(channel)"
        case .legacyChannels: path = "/PTZCtrl/channels"
        case .legacyCapabilities(let channel):
            guard (1...999).contains(channel) else { throw PTZError.invalidSettings }
            path = "/PTZCtrl/channels/\(channel)/capabilities"
        case .legacyConfiguration(let channel):
            guard (1...999).contains(channel) else { throw PTZError.invalidSettings }
            path = "/PTZCtrl/channels/\(channel)"
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
        return try Self.validatedData(data, statusCode: response.statusCode)
    }

    /// Firmware may report an application failure inside an HTTP 200/400 XML
    /// response. Only an explicit unsupported status permits route fallback.
    static func validatedData(_ data: Data, statusCode: Int) throws -> Data {
        if statusCode == 401 || statusCode == 403 { throw PTZError.permissionDenied }
        guard data.count <= 131_072 else { throw PTZError.invalidResponse }
        if [404, 405, 501].contains(statusCode) { throw PTZError.unsupported }
        let classification = try PTZResponseDocument.validate(data)
        guard (200...299).contains(statusCode), classification == .notStatus else { throw PTZError.invalidResponse }
        return data
    }
}

enum PTZCapabilityDocument {
    struct Channel: Equatable, Sendable {
        let id: Int
        let videoInputID: Int?
        let enabled: Bool
        let panSupport: Bool?
        let tiltSupport: Bool?
        let zoomSupport: Bool?

        var hasAxisFlags: Bool { panSupport != nil || tiltSupport != nil || zoomSupport != nil }
    }

    static func channels(_ data: Data) throws -> [Channel] {
        let root = try PTZXMLNode.parse(data)
        guard root.name == "PTZChannelList" else { throw PTZError.invalidResponse }
        var channels: [Channel] = []
        for child in root.children where child.name == "PTZChannel" {
            let channel = try configuration(child)
            guard !channels.contains(where: { $0.id == channel.id }) else { throw PTZError.invalidResponse }
            channels.append(channel)
        }
        return channels
    }

    static func configuration(_ data: Data) throws -> Channel {
        try configuration(PTZXMLNode.parse(data))
    }

    private static func configuration(_ node: PTZXMLNode) throws -> Channel {
        guard node.name == "PTZChannel", let text = node.child("id")?.text,
              let id = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...999).contains(id) else { throw PTZError.invalidResponse }
        var videoInputID: Int?
        if let input = node.child("videoInputID")?.text {
            guard let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)), (1...999).contains(value)
            else { throw PTZError.invalidResponse }
            videoInputID = value
        }
        return Channel(id: id, videoInputID: videoInputID,
                       enabled: try boolean(node.child("enabled")) ?? true,
                       panSupport: try boolean(node.child("panSupport")),
                       tiltSupport: try boolean(node.child("tiltSupport")),
                       zoomSupport: try boolean(node.child("zoomSupport")))
    }

    /// IPMD's original capability resource can use the same PTZChannel root as
    /// its configuration. Only explicit axis flags count; enabled, maximum
    /// speed, presets and current coordinates do not prove movement support.
    static func capabilityResponse(_ data: Data, channel: Int, videoChannel: Int,
                                   configuration: Channel?, apiFamily: PTZAPIFamily) throws -> PTZDiscoveryResult {
        let root = try PTZXMLNode.parse(data)
        guard root.name == "PTZChannel" else {
            return try capabilities(data, channel: channel, configuration: configuration, apiFamily: apiFamily)
        }
        let detail = try self.configuration(root)
        guard detail.id == channel, detail.videoInputID == nil || detail.videoInputID == videoChannel else { return .unknown }
        func merged(_ first: Bool?, _ second: Bool?) -> Bool? {
            if first == false || second == false { return false }
            if first == true || second == true { return true }
            return nil
        }
        let combined = Channel(id: channel, videoInputID: detail.videoInputID,
                               enabled: detail.enabled && configuration?.enabled != false,
                               panSupport: merged(configuration?.panSupport, detail.panSupport),
                               tiltSupport: merged(configuration?.tiltSupport, detail.tiltSupport),
                               zoomSupport: merged(configuration?.zoomSupport, detail.zoomSupport))
        return channelCapabilities(combined, channel: channel, apiFamily: apiFamily)
    }

    /// Each vendor movement space describes one API, not whether the device is
    /// physically fixed. Older firmware may advertise only continuous control.
    /// Hikvision's documented root is spelled PTZChanelCap (one n).
    static func capabilities(_ data: Data, channel: Int, configuration: Channel? = nil,
                             apiFamily: PTZAPIFamily = .isapi) throws -> PTZDiscoveryResult {
        let root = try PTZXMLNode.parse(data)
        guard ["PTZChanelCap", "PTZChannelCap"].contains(root.name) else { throw PTZError.invalidResponse }
        let continuousAllowed = try boolean(root.child("notSupportPTZContinuous")) != true
        let pan = try axis(root: root, timed: "MomentaryPanTiltSpace", continuous: "ContinuousPanTiltSpace",
                           absolute: "AbsolutePanTiltPositionSpace", relative: "RelativePanTiltSpace", range: "XRange",
                           support: configuration?.panSupport, continuousAllowed: continuousAllowed)
        let tilt = try axis(root: root, timed: "MomentaryPanTiltSpace", continuous: "ContinuousPanTiltSpace",
                            absolute: "AbsolutePanTiltPositionSpace", relative: "RelativePanTiltSpace", range: "YRange",
                            support: configuration?.tiltSupport, continuousAllowed: continuousAllowed)
        let zoom = try axis(root: root, timed: "MomentaryZoomSpace", continuous: "ContinuousZoomSpace",
                            absolute: "AbsoluteZoomPositionSpace", relative: "RelativeZoomSpace", range: "ZRange",
                            support: configuration?.zoomSupport, continuousAllowed: continuousAllowed)
        if pan.mode != nil || tilt.mode != nil || zoom.mode != nil {
            return .available(PTZCapabilities(channel: channel, panMode: pan.mode, tiltMode: tilt.mode,
                                              zoomMode: zoom.mode,
                                              supportsContinuousStop: pan.continuousSupported || tilt.continuousSupported || zoom.continuousSupported,
                                              apiFamily: apiFamily))
        }
        if pan.exists || tilt.exists || zoom.exists { return .unsupported }
        if pan.explicitlyAbsent && tilt.explicitlyAbsent && zoom.explicitlyAbsent { return .unavailable }
        return .unknown
    }

    /// The vendor integration guide uses these explicit per-axis flags with
    /// /continuous. A missing capabilities route must not erase that evidence.
    static func channelCapabilities(_ configuration: Channel?, channel: Int,
                                    apiFamily: PTZAPIFamily = .isapi) -> PTZDiscoveryResult {
        guard let configuration else { return .unknown }
        guard configuration.enabled else { return .unavailable }
        if configuration.panSupport == true || configuration.tiltSupport == true || configuration.zoomSupport == true {
            return .available(PTZCapabilities(channel: channel,
                                              panMode: configuration.panSupport == true ? .continuous : nil,
                                              tiltMode: configuration.tiltSupport == true ? .continuous : nil,
                                              zoomMode: configuration.zoomSupport == true ? .continuous : nil,
                                              apiFamily: apiFamily))
        }
        if configuration.panSupport == false && configuration.tiltSupport == false && configuration.zoomSupport == false {
            return .unavailable
        }
        return .unknown
    }

    private struct Axis {
        let mode: PTZMovementMode?
        let exists: Bool
        let explicitlyAbsent: Bool
        let continuousSupported: Bool
    }

    private static func axis(root: PTZXMLNode, timed: String, continuous: String, absolute: String,
                             relative: String, range: String, support: Bool?, continuousAllowed: Bool) throws -> Axis {
        let timedRange = try hasRange(root.child(timed), axis: range)
        let continuousRange = try hasRange(root.child(continuous), axis: range)
        let absoluteRange = try hasRange(root.child(absolute), axis: range)
        let relativeRange = try hasRange(root.child(relative), axis: range)
        // Explicit axis flags also distinguish motorized-zoom fixed cameras.
        if support == false { return Axis(mode: nil, exists: false, explicitlyAbsent: true, continuousSupported: false) }
        // An explicit legacy axis flag independently advertises /continuous;
        // unrelated absolute/relative spaces must not erase that evidence.
        let continuousSupported = continuousAllowed && (continuousRange == true || support == true)
        if continuousSupported {
            return Axis(mode: .continuous, exists: true, explicitlyAbsent: false, continuousSupported: true)
        }
        if timedRange == true {
            return Axis(mode: .momentary, exists: true, explicitlyAbsent: false, continuousSupported: false)
        }
        let positionOnly = absoluteRange == true || relativeRange == true
        return Axis(mode: nil, exists: support == true || continuousRange == true || positionOnly,
                    explicitlyAbsent: false, continuousSupported: false)
    }

    /// nil means unadvertised. Zero span does not prove there is no physical
    /// axis: it may only mean this particular movement API is unsupported.
    private static func hasRange(_ space: PTZXMLNode?, axis: String) throws -> Bool? {
        guard let space, let range = space.child(axis) else { return nil }
        guard let lowText = range.child("Min")?.text, let highText = range.child("Max")?.text,
              let low = Double(lowText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let high = Double(highText.trimmingCharacters(in: .whitespacesAndNewlines)),
              low.isFinite, high.isFinite, high >= low else { throw PTZError.invalidResponse }
        return high > low
    }

    private static func boolean(_ node: PTZXMLNode?) throws -> Bool? {
        guard let node else { return nil }
        switch node.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: throw PTZError.invalidResponse
        }
    }
}

@MainActor
enum PTZCapabilityDetector {
    static func detect(configuration: CameraConfiguration, transport: any PTZDiscoveryTransport) async throws -> PTZDiscoveryResult {
        let modern = try await detect(configuration: configuration, transport: transport, apiFamily: .isapi)
        guard modern.allRoutesUnsupported else { return modern.result }
        try Task.checkCancellation()
        return try await detect(configuration: configuration, transport: transport, apiFamily: .legacy).result
    }

    private struct Attempt {
        let result: PTZDiscoveryResult
        var allRoutesUnsupported = false
    }

    private static func detect(configuration: CameraConfiguration, transport: any PTZDiscoveryTransport,
                               apiFamily: PTZAPIFamily) async throws -> Attempt {
        // A device's explicit videoInputID mapping is authoritative. A legacy
        // control ID is only a fallback where that mapping is not supplied.
        var channel = configuration.ptzEnabled ? configuration.ptzChannel : configuration.channel
        var channelConfiguration: PTZCapabilityDocument.Channel?
        var collectionUnsupported = false
        do {
            let data = try await transport.get(PTZDiscoveryResource.channels.inFamily(apiFamily))
            let channels = try PTZCapabilityDocument.channels(data)
            try Task.checkCancellation()
            // The vendor schema explicitly links control IDs to video inputs.
            // Never assume equal IDs when a device supplies that mapping.
            let mapped = channels.filter { $0.videoInputID == configuration.channel }
            let candidate: PTZCapabilityDocument.Channel?
            if mapped.count == 1 { candidate = mapped[0] }
            else if !mapped.isEmpty { return Attempt(result: .unknown) }
            else if let matching = channels.first(where: { $0.id == channel && $0.videoInputID == nil }) { candidate = matching }
            else { candidate = nil }
            if let candidate {
                guard candidate.enabled else { return Attempt(result: .unavailable) }
                channel = candidate.id
                channelConfiguration = candidate
            } else if !channels.isEmpty {
                return Attempt(result: .unknown)
            }
            // Some front-end firmware has an empty collection but exposes the
            // individual capability route. Query only the configured channel.
        } catch PTZError.unsupported {
            collectionUnsupported = true
            // Some firmware exposes capabilities without the collection route.
            // Probe only the matching channel; never scan or guess NVR channels.
        }
        let capabilityData: Data?
        let result: PTZDiscoveryResult
        do {
            let data = try await transport.get(PTZDiscoveryResource.capabilities(channel).inFamily(apiFamily))
            try Task.checkCancellation()
            let parsed = try PTZCapabilityDocument.capabilityResponse(data, channel: channel, videoChannel: configuration.channel,
                                                                      configuration: channelConfiguration, apiFamily: apiFamily)
            capabilityData = data
            result = parsed
        } catch PTZError.unsupported {
            capabilityData = nil
            result = PTZCapabilityDocument.channelCapabilities(channelConfiguration, channel: channel, apiFamily: apiFamily)
        }
        if case .available = result { return Attempt(result: result) }
        if case .unavailable = result { return Attempt(result: result) }
        guard channelConfiguration?.hasAxisFlags != true else { return Attempt(result: result) }
        // Collection firmware sometimes omits axis flags. A precise read of the
        // same control channel is safe; never enumerate other recorder inputs.
        do {
            let data = try await transport.get(PTZDiscoveryResource.configuration(channel).inFamily(apiFamily))
            try Task.checkCancellation()
            let detail = try PTZCapabilityDocument.configuration(data)
            guard detail.id == channel,
                  detail.videoInputID == nil || detail.videoInputID == configuration.channel else { return Attempt(result: .unknown) }
            guard detail.enabled else { return Attempt(result: .unavailable) }
            if let capabilityData {
                // Keep the original continuous veto when merging legacy flags.
                return Attempt(result: try PTZCapabilityDocument.capabilityResponse(capabilityData, channel: channel,
                                          videoChannel: configuration.channel, configuration: detail, apiFamily: apiFamily))
            }
            return Attempt(result: PTZCapabilityDocument.channelCapabilities(detail, channel: channel, apiFamily: apiFamily))
        } catch PTZError.unsupported {
            // Do not route around authentication, malformed XML, an explicit
            // negative, an ambiguous channel mapping or an advertised method
            // we cannot implement. Only absent ISAPI routes try the old API.
            return Attempt(result: result, allRoutesUnsupported: collectionUnsupported && capabilityData == nil)
        }
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

    func detect(configuration: CameraConfiguration, password: String, forceRefresh: Bool = false) async throws -> PTZDiscoveryResult {
        try Task.checkCancellation()
        let camera = try configuration.validated()
        let key = Key(host: camera.host.lowercased(), port: camera.controlPort, https: camera.controlUseHTTPS,
                      username: camera.username, passwordHash: Data(SHA256.hash(data: Data(password.utf8))),
                      videoChannel: camera.channel, legacyChannel: camera.ptzEnabled ? camera.ptzChannel : nil)
        if forceRefresh { cache[key] = nil }
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
                self.cache[key] = Entry(result: result, expires: Date().addingTimeInterval(result.cacheDuration))
                return result
            }
            pending[key] = task
        }
        let result = await task.value
        try Task.checkCancellation()
        return result
    }
}
