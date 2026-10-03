import CryptoKit
import Foundation
@preconcurrency import Network
import XCTest
@testable import Luma

/// These tests exercise CFNetwork, authentication, and real loopback TCP sockets.
/// A URLProtocol replacement cannot establish connection or Digest-cache reuse.
final class PTZHTTPIntegrationTests: XCTestCase {
    @MainActor
    func testReadinessAuthenticatesWithoutMovementAndFirstPressReusesConnection() async throws {
        try await exercise { fixture in
            let service = try fixture.service()
            await service.prepare()
            XCTAssertEqual(fixture.statusReads, 1)
            XCTAssertTrue(fixture.accepted.isEmpty, "Readiness must not move or stop a camera.")
            let challenges = fixture.challengeCount
            let started = ContinuousClock.now
            try await service.send(PTZCommand(direction: .left, mode: .continuous))
            let elapsed = started.duration(to: .now)
            fixture.mark("prepared first press response: \(elapsed)")
            XCTAssertLessThan(elapsed, .milliseconds(500))
            XCTAssertEqual(fixture.challengeCount, challenges,
                           "The first movement must reuse the GET's authenticated protection space.")
            XCTAssertEqual(fixture.accepted.first?.peerID, fixture.lastStatusPeer)
            try await service.send(.stop)
        }
    }

    @MainActor
    func testStalledReadinessCannotDelayMovementOrIndependentStop() async throws {
        try await exercise { fixture in
            let service = try fixture.service()
            fixture.holdStatusReply = true
            let readiness = Task { await service.prepare() }
            defer { readiness.cancel() }
            try await fixture.wait("Readiness did not reach its read-only status endpoint.") { fixture.statusReads == 1 }
            fixture.holdNextMoveReply = true
            let movement = Task { try await service.send(PTZCommand(direction: .right, mode: .continuous)) }
            defer { fixture.releaseMoveReply(); movement.cancel() }
            try await fixture.wait("A stalled readiness GET delayed movement.", timeout: .milliseconds(500)) {
                fixture.heldMove != nil
            }
            let released = ContinuousClock.now
            try await service.send(.stop)
            let elapsed = released.duration(to: .now)
            fixture.mark("Stop during held GET and Move: \(elapsed)")
            XCTAssertLessThan(elapsed, .milliseconds(500))
            XCTAssertEqual(fixture.stopCount, 1)
            XCTAssertEqual(fixture.moveReplies, 0)
            fixture.releaseMoveReply()
            try await movement.value
            // Keep the independent request-order safety contract in the test too.
            try await service.send(.stop)
            await readiness.value
        }
    }

    @MainActor
    func testUnsupportedReadinessDoesNotDisableWorkingControls() async throws {
        try await exercise { fixture in
            fixture.statusIsUnsupported = true
            let service = try fixture.service()
            await service.prepare()
            XCTAssertTrue(fixture.accepted.isEmpty)
            try await service.send(PTZCommand(direction: .zoomIn, mode: .continuous))
            try await service.send(.stop)
            XCTAssertEqual(fixture.accepted.map(\.isStop), [false, true])
        }
    }

    @MainActor
    func testDigestAndKeepAliveAreReusedAcrossMovesAndStops() async throws {
        try await exercise { fixture in
            let service = try fixture.service()
            for command in [PTZCommand(direction: .left, mode: .continuous), .stop,
                            PTZCommand(direction: .right, mode: .continuous), .stop] {
                try await service.send(command)
            }
            XCTAssertEqual(fixture.accepted.map(\.isStop), [false, true, false, true])
            XCTAssertEqual(Set(fixture.accepted.map(\.peerID)).count, 1,
                           "Sequential PTZ commands must reuse the keep-alive connection.")
            XCTAssertEqual(fixture.challengeCount, 1,
                           "The same session must retain its authenticated protection space.")
            XCTAssertEqual(fixture.rejectedCredentials, 0)
        }
    }

    @MainActor
    func testReleaseSendsStopBeforeMoveReplyAndConfirmsAgainAfterLateReply() async throws {
        try await exercise { fixture in
            fixture.holdNextMoveReply = true
            let controller = PTZController(enabled: true, transport: try fixture.service(),
                                           capabilities: PTZCapabilities(channel: 1, panMode: .continuous,
                                                                         tiltMode: .continuous, zoomMode: .continuous),
                                           holdLimit: .seconds(3))
            defer {
                if controller.isMoving || controller.isStopping {
                    fixture.releaseMoveReply()
                    controller.stop()
                }
            }
            controller.press(.left)
            try await fixture.wait("The move never reached the HTTP server.") { fixture.heldMove != nil }

            let releaseTime = ContinuousClock.now
            controller.stop()
            var heartbeat = false
            let heartbeatTask = Task { @MainActor in heartbeat = true }
            defer { heartbeatTask.cancel() }
            try await fixture.wait("Stop waited for the unanswered move instead of using the second connection.",
                                   timeout: .seconds(1)) { fixture.stopCount >= 1 }
            let stopLatency = releaseTime.duration(to: ContinuousClock.now)
            fixture.mark("release-to-Stop receipt: \(stopLatency)")
            XCTAssertLessThan(stopLatency, .seconds(1))
            XCTAssertTrue(heartbeat, "A pending request must not block the main actor.")
            XCTAssertEqual(fixture.moveReplies, 0, "The first Stop must precede the delayed move response.")
            XCTAssertTrue(controller.isStopping, "An early Stop ACK cannot settle the still-unresolved move.")
            let nextIntent = try XCTUnwrap(controller.press(.right))
            controller.release(token: nextIntent)
            XCTAssertEqual(fixture.accepted.filter { !$0.isStop }.count, 1)

            fixture.releaseMoveReply()
            try await fixture.wait("A late move response was not followed by a final confirmed Stop.") {
                fixture.accepted.contains { $0.isStop && $0.moveRepliesAtReceipt > 0 } && !controller.isStopping
            }
            XCTAssertEqual(fixture.accepted.filter { !$0.isStop }.count, 1,
                           "Releasing the replacement intent before settlement must prevent its move request.")
            XCTAssertGreaterThanOrEqual(fixture.stopCount, 2)
            XCTAssertEqual(fixture.moveReplies, 1)
            XCTAssertFalse(controller.isMoving)
            XCTAssertNil(controller.errorMessage)
            XCTAssertEqual(Set(fixture.accepted.map(\.peerID)).count, 2,
                           "The held move and prompt Stop must use separate real TCP connections.")
        }
    }

    @MainActor
    func testAuthenticatedServiceDoesNotLendCredentialsToAnotherService() async throws {
        try await exercise { fixture in
            let valid = try fixture.service()
            try await valid.send(.stop)
            let invalid = try fixture.service(password: "incorrect-synthetic-password")
            do {
                try await invalid.send(PTZCommand(direction: .left, mode: .continuous))
                XCTFail("A new service used credentials retained by another service.")
            } catch {
                XCTAssertTrue(error is PTZError)
                XCTAssertFalse(error.localizedDescription.contains("incorrect-synthetic-password"))
                XCTAssertFalse(error.localizedDescription.contains(fixture.password))
            }
            XCTAssertEqual(fixture.accepted.map(\.isStop), [true])
            XCTAssertGreaterThanOrEqual(fixture.rejectedCredentials, 1)
        }
    }

    @MainActor
    private func exercise(_ body: (PTZHTTPFixture) async throws -> Void) async throws {
        let fixture = PTZHTTPFixture()
        defer {
            fixture.stop()
            let attachment = XCTAttachment(string: fixture.diagnostics)
            attachment.name = "PTZ HTTP phases.txt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        do {
            try await fixture.start()
            try await body(fixture)
        } catch {
            XCTFail("PTZ HTTP integration failed: \(error)")
            throw error
        }
    }
}

@MainActor
private final class PTZHTTPFixture {
    struct AcceptedRequest {
        let peerID: UUID
        let isStop: Bool
        let moveRepliesAtReceipt: Int
    }

    // Password punctuation deliberately includes URL-reserved and Digest-quoted
    // characters. Only its hash is sent; diagnostics never contain credentials.
    let password = "Lan@:#/%?& +\"\\!"
    let username = "viewer"
    private let realm = "Luma PTZ integration"
    private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var port: UInt16?
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var listenerFailure = false
    private var began = ContinuousClock.now
    private var timeline: [String] = []
    private(set) var accepted: [AcceptedRequest] = []
    private(set) var challengeCount = 0
    private(set) var rejectedCredentials = 0
    private(set) var moveReplies = 0
    private(set) var heldMove: UUID?
    private(set) var statusReads = 0
    private(set) var lastStatusPeer: UUID?
    var holdStatusReply = false
    var statusIsUnsupported = false
    var holdNextMoveReply = false
    var stopCount: Int { accepted.filter(\.isStop).count }

    var diagnostics: String {
        (timeline + ["accepted=\(accepted.count), challenges=\(challengeCount), rejected=\(rejectedCredentials), moveReplies=\(moveReplies)"])
            .joined(separator: "\n")
    }

    func mark(_ message: String) { timeline.append("+\(began.duration(to: ContinuousClock.now)) \(message)") }

    func service(password: String? = nil) throws -> PTZService {
        guard let port else { throw FixtureFailure("No loopback listener port.") }
        let camera = CameraConfiguration(name: "Synthetic PTZ", host: "127.0.0.1", username: username,
                                         ptzEnabled: true, controlPort: Int(port))
        return PTZService(configuration: camera, password: password ?? self.password)
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let next = try NWListener(using: parameters)
        listener = next
        next.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.port = self.listener?.port?.rawValue
                case .failed: self.listenerFailure = true
                default: break
                }
            }
        }
        next.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        next.start(queue: .main)
        try await wait("HTTP listener did not become ready.") { self.port != nil || self.listenerFailure }
        guard port != nil else { throw FixtureFailure("HTTP listener failed.") }
        mark("listener ready")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll()
        heldMove = nil
    }

    func wait(_ failure: String, timeout: Duration = .seconds(3), until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FixtureFailure(failure) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseMoveReply() {
        guard let id = heldMove, let peer = peers[id] else { return }
        heldMove = nil
        moveReplies += 1
        mark("delayed move response released")
        reply(peer, status: "200 OK", body: Self.success)
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        let peer = Peer(connection)
        peers[peer.id] = peer
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
                    peer.connection.cancel()
                    self.peers.removeValue(forKey: peer.id)
                } else if self.peers[peer.id] != nil { self.receive(peer) }
            }
        }
    }

    private func consume(_ peer: Peer) {
        while !peer.input.isEmpty {
            guard peer.input.count <= 65_536 else { close(peer); return }
            guard let separator = peer.input.range(of: Data("\r\n\r\n".utf8)) else { return }
            let text = String(decoding: peer.input[..<separator.lowerBound], as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3 else { close(peer); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let length = Int(headers["content-length"] ?? "0"), (0...32_768).contains(length) else { close(peer); return }
            let headerLength = peer.input.distance(from: peer.input.startIndex, to: separator.upperBound)
            guard peer.input.count >= headerLength + length else { return }
            let end = peer.input.index(separator.upperBound, offsetBy: length)
            let body = Data(peer.input[separator.upperBound..<end])
            peer.input.removeFirst(headerLength + length)
            handle(method: String(first[0]), target: String(first[1]), headers: headers, body: body, peer: peer)
        }
    }

    private func handle(method: String, target: String, headers: [String: String], body: Data, peer: Peer) {
        let isStatus = method == "GET" && target == "/ISAPI/PTZCtrl/channels/1/status"
        guard isStatus || (method == "PUT" && target == "/ISAPI/PTZCtrl/channels/1/continuous") else {
            reply(peer, status: "404 Not Found")
            return
        }
        guard validDigest(headers["authorization"], method: method, target: target) else {
            challengeCount += 1
            if headers["authorization"] != nil { rejectedCredentials += 1 }
            mark(headers["authorization"] == nil ? "Digest challenge" : "Digest rejected")
            reply(peer, status: "401 Unauthorized", extraHeaders: [
                "WWW-Authenticate": "Digest realm=\"\(realm)\", nonce=\"\(nonce)\", algorithm=MD5, qop=\"auth\""
            ])
            return
        }
        if isStatus {
            statusReads += 1
            lastStatusPeer = peer.id
            mark("authenticated read-only status received")
            if !holdStatusReply {
                reply(peer, status: statusIsUnsupported ? "404 Not Found" : "200 OK",
                      body: Data("<PTZStatus/>".utf8))
            }
            return
        }
        let xml = String(decoding: body, as: UTF8.self)
        guard xml.contains("<PTZData"), xml.contains("</PTZData>") else {
            reply(peer, status: "400 Bad Request")
            return
        }
        let isStop = xml.contains("<pan>0</pan><tilt>0</tilt><zoom>0</zoom>")
        accepted.append(AcceptedRequest(peerID: peer.id, isStop: isStop, moveRepliesAtReceipt: moveReplies))
        mark(isStop ? "authenticated Stop received" : "authenticated move received")
        if !isStop, holdNextMoveReply {
            holdNextMoveReply = false
            heldMove = peer.id
            mark("move response held")
            return
        }
        if !isStop { moveReplies += 1 }
        reply(peer, status: "200 OK", body: Self.success)
    }

    private func validDigest(_ authorization: String?, method: String, target: String) -> Bool {
        guard let authorization, authorization.hasPrefix("Digest "),
              let regex = try? NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"\\]*(?:\\.[^"\\]*)*)"|([^,\s]+))"#) else { return false }
        var fields: [String: String] = [:]
        let text = authorization as NSString
        for match in regex.matches(in: authorization, range: NSRange(location: 0, length: text.length)) {
            let valueRange = match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2)
            fields[text.substring(with: match.range(at: 1)).lowercased()] = text.substring(with: valueRange)
        }
        guard fields["username"] == username, fields["realm"] == realm, fields["nonce"] == nonce,
              fields["uri"] == target, fields["qop"] == "auth",
              let count = fields["nc"], count.count == 8, let number = UInt32(count, radix: 16), number > 0,
              let clientNonce = fields["cnonce"], !clientNonce.isEmpty else { return false }
        let first = Self.md5("\(username):\(realm):\(password)")
        let second = Self.md5("\(method):\(target)")
        let expected = Self.md5("\(first):\(nonce):\(count):\(clientNonce):auth:\(second)")
        return fields["response"]?.lowercased() == expected
    }

    private func reply(_ peer: Peer, status: String, extraHeaders: [String: String] = [:], body: Data = Data()) {
        var lines = ["HTTP/1.1 \(status)", "Content-Length: \(body.count)", "Content-Type: application/xml", "Connection: keep-alive"]
        lines.append(contentsOf: extraHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        peer.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func close(_ peer: Peer) {
        peer.connection.cancel()
        peers.removeValue(forKey: peer.id)
    }

    private static let success = Data("<ResponseStatus><statusCode>1</statusCode></ResponseStatus>".utf8)
    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var input = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private struct FixtureFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
