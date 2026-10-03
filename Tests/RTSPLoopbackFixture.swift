import CryptoKit
import Foundation
@preconcurrency import Network

/// A test-only RTSP 1.0 server. It binds only IPv4 loopback on an ephemeral
/// port, accepts synthetic credentials, and never touches the user's cameras.
/// RTSP framing: RFC 2326 §10.12; Digest: RFC 2069; H.264 RTP: RFC 6184 §5.8.
@MainActor
final class RTSPLoopbackFixture {
    enum Behavior: Equatable { case video, stalledHandshake, delayedSetup(seconds: Double) }

    private(set) var port: UInt16?
    private(set) var requestCount = 0
    private(set) var authenticatedRequests = 0
    private(set) var rejectedCredentials = 0
    private(set) var playRequests = 0
    private(set) var sentVideoPackets = 0
    private(set) var connectionCount = 0
    private(set) var teardownRequests = 0
    private(set) var setupRequests = 0
    private(set) var failure: String?

    private let username: String
    private let password: String
    private let behavior: Behavior
    private let video: RTSPH264Pattern?
    private let realm = "Luma loopback test"
    private let nonce = "0123456789abcdef0123456789abcdef"
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var began = ProcessInfo.processInfo.systemUptime
    private var timeline: [String] = []

    /// Only synthetic protocol phases and relative durations are recorded.
    /// URLs, authorization headers and credentials never enter attachments.
    var diagnostics: String {
        (timeline + ["Totals: connections=\(connectionCount), requests=\(requestCount), authenticated=\(authenticatedRequests), rejected=\(rejectedCredentials), setup=\(setupRequests), play=\(playRequests), teardown=\(teardownRequests), RTP packets=\(sentVideoPackets)"]).joined(separator: "\n")
    }

    func mark(_ event: String) {
        guard timeline.count < 160 else { return }
        timeline.append(String(format: "+%.3fs %@", ProcessInfo.processInfo.systemUptime - began, event))
    }

    init(username: String = "viewer", password: String, behavior: Behavior = .video,
         video: RTSPH264Pattern? = nil) {
        self.username = username
        self.password = password
        self.behavior = behavior
        self.video = video
    }

    func start() async throws {
        began = ProcessInfo.processInfo.systemUptime
        mark("listener starting")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let next = try NWListener(using: parameters)
        listener = next
        next.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue
                    self.mark("listener ready")
                case .failed:
                    self.failure = "The loopback RTSP listener failed."
                    self.mark("listener failed")
                default: break
                }
            }
        }
        next.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        next.start(queue: .main)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while port == nil {
            if let failure { throw RTSPFixtureError.failed(failure) }
            guard ContinuousClock.now < deadline else { throw RTSPFixtureError.failed("Loopback listener readiness timed out.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func stop() {
        if listener != nil { mark("fixture stopped") }
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.stop() }
        peers.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        let peer = Peer(connection: connection)
        peers[peer.id] = peer
        connectionCount += 1
        mark("TCP connection accepted")
        connection.start(queue: .main)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak peer] data, _, complete, error in
            Task { @MainActor in
                guard let self, let peer, self.peers[peer.id] != nil else { return }
                if let data { peer.input.append(data) }
                self.consume(peer)
                if complete || error != nil {
                    self.mark("TCP connection closed")
                    peer.stop()
                    self.peers.removeValue(forKey: peer.id)
                } else if self.peers[peer.id] != nil {
                    self.receive(peer)
                }
            }
        }
    }

    private func consume(_ peer: Peer) {
        while !peer.input.isEmpty {
            if peer.input.count > 65_536 { peer.stop(); peers.removeValue(forKey: peer.id); return }
            // Ignore client RTCP interleaved on the same TCP connection.
            if peer.input.first == 0x24 {
                guard peer.input.count >= 4 else { return }
                let bytes = [UInt8](peer.input.prefix(4))
                let count = 4 + Int(bytes[2]) * 256 + Int(bytes[3])
                guard peer.input.count >= count else { return }
                peer.input.removeFirst(count)
                continue
            }
            guard let separator = peer.input.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = peer.input[..<separator.lowerBound]
            guard let text = String(data: headerData, encoding: .utf8) else { peer.stop(); return }
            let lines = text.components(separatedBy: "\r\n")
            let start = (lines.first ?? "").split(separator: " ")
            guard start.count == 3 else { peer.stop(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
            guard bodyLength >= 0, bodyLength <= 32_768 else { peer.stop(); return }
            let count = peer.input.distance(from: peer.input.startIndex, to: separator.upperBound) + bodyLength
            guard peer.input.count >= count else { return }
            peer.input.removeFirst(count)
            handle(method: String(start[0]), target: String(start[1]), headers: headers, peer: peer)
        }
    }

    private func handle(method: String, target: String, headers: [String: String], peer: Peer) {
        requestCount += 1
        let knownMethods = ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "GET_PARAMETER", "TEARDOWN"]
        mark("request \(knownMethods.contains(method) ? method : "OTHER")")
        guard behavior != .stalledHandshake else { return }
        let sequence = headers["cseq"] ?? "0"
        if method == "OPTIONS" {
            reply(peer, sequence: sequence, headers: ["Public": "OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN"])
            return
        }
        if method == "TEARDOWN" {
            teardownRequests += 1
            reply(peer, sequence: sequence)
            peer.framesTask?.cancel()
            peer.framesTask = nil
            return
        }
        guard validDigest(headers["authorization"], method: method, target: target) else {
            if headers["authorization"] != nil { rejectedCredentials += 1 }
            mark(headers["authorization"] == nil ? "Digest challenge" : "Digest rejected")
            reply(peer, sequence: sequence, status: "401 Unauthorized", headers: [
                "WWW-Authenticate": "Digest realm=\"\(realm)\", nonce=\"\(nonce)\", algorithm=MD5"
            ])
            return
        }
        authenticatedRequests += 1
        mark("Digest accepted")
        let base = "rtsp://127.0.0.1:\(port ?? 0)/Streaming/Channels/102/"
        switch method {
        case "DESCRIBE":
            guard let video else { reply(peer, sequence: sequence, status: "503 Service Unavailable"); return }
            let profile = video.sps.dropFirst().prefix(3).map { String(format: "%02x", $0) }.joined()
            let sdp = [
                "v=0", "o=- 1 1 IN IP4 127.0.0.1", "s=Luma synthetic RTSP test", "c=IN IP4 127.0.0.1", "t=0 0",
                "a=control:*", "a=range:npt=0-", "m=video 0 RTP/AVP 96", "a=rtpmap:96 H264/90000",
                "a=fmtp:96 packetization-mode=1;profile-level-id=\(profile);sprop-parameter-sets=\(video.sps.base64EncodedString()),\(video.pps.base64EncodedString())",
                "a=framerate:10", "a=control:trackID=0", ""
            ].joined(separator: "\r\n")
            reply(peer, sequence: sequence, headers: ["Content-Type": "application/sdp", "Content-Base": base], body: Data(sdp.utf8))
        case "SETUP":
            setupRequests += 1
            guard (headers["transport"] ?? "").uppercased().contains("RTP/AVP/TCP") else {
                reply(peer, sequence: sequence, status: "461 Unsupported Transport"); return
            }
            if case .delayedSetup(let seconds) = behavior {
                mark(String(format: "SETUP response delayed %.3fs", seconds))
                // Deliberately exceed the former 15-second startup watchdog.
                // One delayed track reproduces the camera's slow two-track
                // negotiation without pretending to transmit synthetic audio.
                peer.handshakeTask = Task { @MainActor [weak self, weak peer] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self, let peer, self.peers[peer.id] != nil else { return }
                    self.setupReply(peer, sequence: sequence)
                }
            } else {
                setupReply(peer, sequence: sequence)
            }
        case "PLAY":
            playRequests += 1
            reply(peer, sequence: sequence, headers: ["Session": "LumaFixture;timeout=60", "Range": "npt=0.000-", "RTP-Info": "url=\(base)trackID=0;seq=1000;rtptime=0"])
            stream(peer)
        case "GET_PARAMETER": reply(peer, sequence: sequence, headers: ["Session": "LumaFixture"])
        default: reply(peer, sequence: sequence, status: "405 Method Not Allowed")
        }
    }

    private func setupReply(_ peer: Peer, sequence: String) {
        reply(peer, sequence: sequence, headers: ["Session": "LumaFixture;timeout=60", "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=12345678"])
    }

    private func validDigest(_ authorization: String?, method: String, target: String) -> Bool {
        guard let authorization, authorization.hasPrefix("Digest "),
              let expression = try? NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"([^"]*)"|([^,\s]+))"#) else { return false }
        let text = authorization as NSString
        var fields: [String: String] = [:]
        for match in expression.matches(in: authorization, range: NSRange(location: 0, length: text.length)) {
            let value = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            fields[text.substring(with: match.range(at: 1)).lowercased()] = text.substring(with: value)
        }
        guard fields["username"] == username, fields["realm"] == realm,
              fields["nonce"] == nonce, let digestURI = fields["uri"] else { return false }
        // LIVE555 authenticates SETUP using the presentation's base URL even
        // when the request targets its SDP track. Accept only this fixture's
        // known presentation/track URLs and still verify the password digest.
        let presentation = "rtsp://127.0.0.1:\(port ?? 0)/Streaming/Channels/102/"
        guard digestURI == target || (method == "SETUP" && target == presentation + "trackID=0"
                                      && digestURI == presentation) else { return false }
        let a1 = Self.md5("\(username):\(realm):\(password)")
        let a2 = Self.md5("\(method):\(digestURI)")
        let expected = Self.md5("\(a1):\(nonce):\(a2)")
        return fields["response"]?.lowercased() == expected
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func reply(_ peer: Peer, sequence: String, status: String = "200 OK", headers: [String: String] = [:], body: Data = Data()) {
        mark("response \(status)")
        var lines = ["RTSP/1.0 \(status)", "CSeq: \(sequence)", "Server: LumaLoopbackFixture", "Content-Length: \(body.count)"]
        lines += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        send(data, peer: peer)
    }

    private func stream(_ peer: Peer) {
        guard let video, peer.framesTask == nil else { return }
        let connection = peer.connection
        // XCTest's synchronous tap/pinch calls occupy the runner's main actor.
        // A camera keeps transmitting during those gestures; this fixture must
        // do so as well, rather than manufacturing a multi-second video stall.
        peer.framesTask = Task.detached { [weak self] in
            var frameIndex = 0
            var sequence: UInt16 = 1000
            var timestamp: UInt32 = 0
            var packetCount: UInt32 = 0
            var octetCount: UInt32 = 0
            while !Task.isCancelled {
                if frameIndex.isMultiple(of: 10) {
                    let report = Self.senderReport(timestamp: timestamp, packets: packetCount, octets: octetCount)
                    connection.send(content: report, completion: .contentProcessed { _ in })
                }
                let frame = video.frames[frameIndex % video.frames.count]
                var packetsInFrame = 0
                for (index, nal) in frame.enumerated() {
                    let payloads = Self.payloads(nal)
                    for (part, payload) in payloads.enumerated() {
                        let marker: UInt8 = index == frame.count - 1 && part == payloads.count - 1 ? 0x80 : 0
                        var packet = Data([0x80, 96 | marker, UInt8(sequence >> 8), UInt8(sequence & 255)])
                        packet.append(contentsOf: [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 255), UInt8((timestamp >> 8) & 255), UInt8(timestamp & 255), 0x12, 0x34, 0x56, 0x78])
                        packet.append(payload)
                        var interleaved = Data([0x24, 0, UInt8(packet.count >> 8), UInt8(packet.count & 255)])
                        interleaved.append(packet)
                        connection.send(content: interleaved, completion: .contentProcessed { _ in })
                        packetsInFrame += 1
                        packetCount &+= 1
                        octetCount &+= UInt32(payload.count)
                        sequence &+= 1
                    }
                }
                Task { @MainActor [weak self, packetsInFrame] in
                    guard let self else { return }
                    if self.sentVideoPackets == 0 { self.mark("first RTP packet sent") }
                    self.sentVideoPackets += packetsInFrame
                }
                timestamp &+= 9_000
                frameIndex += 1
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private nonisolated static func senderReport(timestamp: UInt32, packets: UInt32, octets: UInt32) -> Data {
        // RFC 3550 sender reports map the 90 kHz video clock to wall time.
        let ntp = Date().timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(ntp)
        let fraction = UInt32((ntp - floor(ntp)) * 4_294_967_296)
        var packet = Data([0x80, 200, 0, 6])
        for value in [UInt32(0x12345678), seconds, fraction, timestamp, packets, octets] {
            packet.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
        }
        var interleaved = Data([0x24, 1, 0, UInt8(packet.count)])
        interleaved.append(packet)
        return interleaved
    }

    private nonisolated static func payloads(_ nal: Data) -> [Data] {
        guard nal.count > 1_200, let header = nal.first else { return [nal] }
        let bytes = [UInt8](nal.dropFirst())
        return stride(from: 0, to: bytes.count, by: 1_198).map { start in
            let end = min(start + 1_198, bytes.count)
            let flags: UInt8 = (start == 0 ? 0x80 : 0) | (end == bytes.count ? 0x40 : 0)
            var fragment = Data([(header & 0xE0) | 28, (header & 0x1F) | flags])
            fragment.append(contentsOf: bytes[start..<end])
            return fragment
        }
    }

    private func send(_ data: Data, peer: Peer) {
        peer.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    @MainActor private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var input = Data()
        var framesTask: Task<Void, Never>?
        var handshakeTask: Task<Void, Never>?
        init(connection: NWConnection) { self.connection = connection }
        func stop() {
            framesTask?.cancel(); framesTask = nil
            handshakeTask?.cancel(); handshakeTask = nil
            connection.cancel()
        }
    }
}

enum RTSPFixtureError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}
