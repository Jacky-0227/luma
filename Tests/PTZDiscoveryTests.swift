import XCTest
@testable import Luma

final class PTZDiscoveryTests: XCTestCase {
    func testDiscoveryRequestsAreReadOnlyAndCredentialFree() throws {
        let configuration = CameraConfiguration(name: "Test", host: "camera.local", ptzEnabled: false,
                                                controlPort: 8443, controlUseHTTPS: true)
        let endpoint = try PTZEndpoint(configuration: configuration, requireEnabled: false)
        for resource in [PTZDiscoveryResource.channels, .capabilities(3)] {
            let request = try resource.request(endpoint: endpoint)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.url?.user)
            XCTAssertNil(request.url?.password)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.host, "camera.local")
            XCTAssertEqual(request.url?.port, 8443)
        }
        XCTAssertThrowsError(try PTZDiscoveryResource.capabilities(0).request(endpoint: endpoint))
    }

    @MainActor
    func testCapabilitiesAutomaticallySelectMatchingNVRChannel() async throws {
        let transport = CapabilityTransport(channels: [1, 3], capability: Self.timedCapabilities)
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 3)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 3, panTilt: true, zoom: true)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(3)])

        let different = CapabilityTransport(channels: [1, 3], capability: Self.timedCapabilities)
        let unknown = try await PTZCapabilityDetector.detect(configuration: CameraConfiguration(name: "Test", host: "camera.local", channel: 2), transport: different)
        XCTAssertEqual(unknown, .unknown)
        XCTAssertEqual(different.requests, [.channels], "Never offer controls for a different recorder channel.")
    }

    @MainActor
    func testDeviceVideoInputMappingOverridesControlIDAndHonorsDisabledChannel() async throws {
        let transport = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        transport.channelXML = Data("<PTZChannelList><PTZChannel><id>7</id><enabled>true</enabled><videoInputID>3</videoInputID></PTZChannel></PTZChannelList>".utf8)
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 3)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 7, panTilt: true, zoom: true)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(7)])
        let disabled = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        disabled.channelXML = Data("<PTZChannelList><PTZChannel><id>7</id><enabled>false</enabled><videoInputID>3</videoInputID></PTZChannel></PTZChannelList>".utf8)
        let disabledResult = try await PTZCapabilityDetector.detect(configuration: camera, transport: disabled)
        XCTAssertEqual(disabledResult, .unavailable)
        XCTAssertEqual(disabled.requests, [.channels])
    }

    @MainActor
    func testNoChannelsAndMissingTimedCapabilitiesDoNotEnableControls() async throws {
        let transport = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        let result = try await PTZCapabilityDetector.detect(configuration: Self.camera, transport: transport)
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(transport.requests, [.channels])
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(Data("<PTZChanelCap><maxPresetNum>0</maxPresetNum></PTZChanelCap>".utf8), channel: 1), .unavailable)
        XCTAssertThrowsError(try PTZCapabilityDocument.capabilities(Data("<html>login</html>".utf8), channel: 1))
        XCTAssertThrowsError(try PTZCapabilityDocument.channels(Data("<!DOCTYPE x><PTZChannelList/>".utf8)))
        let utf16Entity = try XCTUnwrap("<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE PTZChannelList [<!ENTITY nested \"1\">]><PTZChannelList><PTZChannel><id>&nested;</id></PTZChannel></PTZChannelList>".data(using: .utf16))
        XCTAssertThrowsError(try PTZCapabilityDocument.channels(utf16Entity))
    }

    @MainActor
    func testMissingCollectionFallsBackOnlyToRequestedChannel() async throws {
        let transport = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        transport.collectionError = .unsupported
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 4)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 4, panTilt: true, zoom: true)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(4)])
    }

    @MainActor
    func testFailedDetectionIsUnknownAndDoesNotFloodRepeatedOpens() async throws {
        let transport = CapabilityTransport(channels: [1], capability: Self.timedCapabilities)
        transport.collectionError = .permissionDenied
        let discovery = PTZDiscovery { _, _ in transport }
        let first = try await discovery.detect(configuration: Self.camera, password: "test")
        let second = try await discovery.detect(configuration: Self.camera, password: "test")
        XCTAssertEqual(first, .unknown)
        XCTAssertEqual(second, .unknown)
        XCTAssertEqual(transport.requests, [.channels])
        _ = try await discovery.detect(configuration: Self.camera, password: "changed-test-password")
        XCTAssertEqual(transport.requests, [.channels, .channels], "Changing credentials must not reuse an old result.")
    }

    @MainActor
    func testCancellationDiscardsOnlyThatWaiterAndConcurrentOpensShareRead() async throws {
        let transport = CapabilityTransport(channels: [1], capability: Self.timedCapabilities)
        transport.blockCollection = true
        let discovery = PTZDiscovery { _, _ in transport }
        let first = Task { @MainActor in try await discovery.detect(configuration: Self.camera, password: "test") }
        await transport.waitUntilBlocked()
        let second = Task { @MainActor in try await discovery.detect(configuration: Self.camera, password: "test") }
        first.cancel()
        transport.releaseCollection()
        do {
            _ = try await first.value
            XCTFail("A cancelled presentation must not accept the detection result.")
        } catch is CancellationError { }
        let result = try await second.value
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 1, panTilt: true, zoom: true)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(1)])
    }

    private static var camera: CameraConfiguration { CameraConfiguration(name: "Test", host: "camera.local") }
    private static let timedCapabilities = Data("""
    <PTZChanelCap xmlns="http://www.isapi.org/ver20/XMLSchema" version="2.0">
      <MomentaryPanTiltSpace><XRange><Min>-1</Min><Max>1</Max></XRange><YRange><Min>-1</Min><Max>1</Max></YRange></MomentaryPanTiltSpace>
      <MomentaryZoomSpace><ZRange><Min>-1</Min><Max>1</Max></ZRange></MomentaryZoomSpace>
    </PTZChanelCap>
    """.utf8)
}

@MainActor
private final class CapabilityTransport: PTZDiscoveryTransport {
    let channels: [Int]
    let capability: Data
    var collectionError: PTZError?
    var channelXML: Data?
    var blockCollection = false
    private(set) var requests: [PTZDiscoveryResource] = []
    private var blocked: CheckedContinuation<Void, Never>?

    init(channels: [Int], capability: Data) { self.channels = channels; self.capability = capability }
    func get(_ resource: PTZDiscoveryResource) async throws -> Data {
        requests.append(resource)
        switch resource {
        case .channels:
            if blockCollection { await withCheckedContinuation { blocked = $0 } }
            if let collectionError { throw collectionError }
            if let channelXML { return channelXML }
            return Data(("<PTZChannelList>" + channels.map { "<PTZChannel><id>\($0)</id></PTZChannel>" }.joined() + "</PTZChannelList>").utf8)
        case .capabilities: return capability
        }
    }
    func waitUntilBlocked() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while blocked == nil && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(blocked)
    }
    func releaseCollection() { blocked?.resume(); blocked = nil }
}
