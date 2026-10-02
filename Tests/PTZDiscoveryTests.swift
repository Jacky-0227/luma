import XCTest
@testable import Luma

final class PTZDiscoveryTests: XCTestCase {
    func testDiscoveryRequestsAreReadOnlyAndCredentialFree() throws {
        let configuration = CameraConfiguration(name: "Test", host: "camera.local", ptzEnabled: false,
                                                controlPort: 8443, controlUseHTTPS: true)
        let endpoint = try PTZEndpoint(configuration: configuration, requireEnabled: false)
        for resource in [PTZDiscoveryResource.channels, .capabilities(3), .configuration(3)] {
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
        XCTAssertThrowsError(try PTZDiscoveryResource.configuration(1000).request(endpoint: endpoint))
        XCTAssertEqual(try PTZDiscoveryResource.configuration(3).request(endpoint: endpoint).url?.path, "/ISAPI/PTZCtrl/channels/3")
    }

    @MainActor
    func testCapabilitiesAutomaticallySelectMatchingNVRChannel() async throws {
        let transport = CapabilityTransport(channels: [1, 3], capability: Self.timedCapabilities)
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 3, ptzEnabled: true, ptzChannel: 3)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(Self.momentaryOnlyCapabilities(channel: 3)))
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
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 3, ptzEnabled: true, ptzChannel: 3)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(Self.momentaryOnlyCapabilities(channel: 7)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(7)])
        let disabled = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        disabled.channelXML = Data("<PTZChannelList><PTZChannel><id>7</id><enabled>false</enabled><videoInputID>3</videoInputID></PTZChannel></PTZChannelList>".utf8)
        let disabledResult = try await PTZCapabilityDetector.detect(configuration: camera, transport: disabled)
        XCTAssertEqual(disabledResult, .unavailable)
        XCTAssertEqual(disabled.requests, [.channels])
    }

    @MainActor
    func testEmptyCollectionDoesNotHideAnAvailableMatchingCapability() async throws {
        let transport = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        let result = try await PTZCapabilityDetector.detect(configuration: Self.camera, transport: transport)
        XCTAssertEqual(result, .available(Self.momentaryOnlyCapabilities(channel: 1)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(1)])
    }

    func testAbsentAndMalformedCapabilitiesNeverProveThereIsNoPTZ() throws {
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(Data("<PTZChanelCap><maxPresetNum>0</maxPresetNum></PTZChanelCap>".utf8), channel: 1), .unknown)
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(Data("<PTZChanelCap/>".utf8), channel: 1), .unknown)
        XCTAssertThrowsError(try PTZCapabilityDocument.capabilities(Data("<html>login</html>".utf8), channel: 1))
        XCTAssertThrowsError(try PTZCapabilityDocument.capabilities(Data("<PTZChanelCap><ContinuousPanTiltSpace><XRange><Min>2</Min><Max>1</Max></XRange></ContinuousPanTiltSpace></PTZChanelCap>".utf8), channel: 1))
        XCTAssertThrowsError(try PTZCapabilityDocument.channels(Data("<!DOCTYPE x><PTZChannelList/>".utf8)))
        let utf16Entity = try XCTUnwrap("<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE PTZChannelList [<!ENTITY nested \"1\">]><PTZChannelList><PTZChannel><id>&nested;</id></PTZChannel></PTZChannelList>".data(using: .utf16))
        XCTAssertThrowsError(try PTZCapabilityDocument.channels(utf16Entity))
    }

    func testContinuousOnlyOfficialSpacesAndHikvisionNamespaceEnableSupportedAxes() throws {
        let result = try PTZCapabilityDocument.capabilities(Self.continuousCapabilities, channel: 2)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 2, panMode: .continuous, tiltMode: .continuous, zoomMode: .continuous)))
        let panOnly = Data("""
        <h:PTZChannelCap xmlns:h="http://www.isapi.org/ver20/XMLSchema">
          <h:ContinuousPanTiltSpace><h:XRange><h:Min>-1</h:Min><h:Max>1</h:Max></h:XRange></h:ContinuousPanTiltSpace>
        </h:PTZChannelCap>
        """.utf8)
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(panOnly, channel: 1),
                       .available(PTZCapabilities(channel: 1, panMode: .continuous, tiltMode: nil, zoomMode: nil)))
    }

    func testMovementModeIsSelectedPerAxisWithMomentaryPreferred() throws {
        let data = Data("""
        <PTZChanelCap>
          <MomentaryPanTiltSpace><XRange><Min>-1</Min><Max>1</Max></XRange><YRange><Min>0</Min><Max>0</Max></YRange></MomentaryPanTiltSpace>
          <ContinuousPanTiltSpace><XRange><Min>-1</Min><Max>1</Max></XRange><YRange><Min>-1</Min><Max>1</Max></YRange></ContinuousPanTiltSpace>
          <ContinuousZoomSpace><ZRange><Min>-1</Min><Max>1</Max></ZRange></ContinuousZoomSpace>
        </PTZChanelCap>
        """.utf8)
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(data, channel: 1),
                       .available(PTZCapabilities(channel: 1, panMode: .momentary, tiltMode: .continuous, zoomMode: .continuous)))
    }

    @MainActor
    func testExplicitAxisFlagsKeepZoomOnlyCameraFromReceivingPanTiltControls() async throws {
        let transport = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        transport.channelXML = Self.channelList(pan: false, tilt: false, zoom: true)
        let result = try await PTZCapabilityDetector.detect(configuration: Self.camera, transport: transport)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 1, panMode: nil, tiltMode: nil, zoomMode: .momentary)))
        transport.channelXML = Self.channelList(pan: false, tilt: false, zoom: false)
        let fixed = try await PTZCapabilityDetector.detect(configuration: Self.camera, transport: transport)
        XCTAssertEqual(fixed, .unavailable, "Explicit per-axis negatives override generic range templates.")
    }

    @MainActor
    func testLegacyAxisFlagsSurviveMissingCapabilityRoute() async throws {
        let transport = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        transport.channelXML = Self.channelList(pan: true, tilt: true, zoom: false)
        transport.capabilityError = .unsupported
        let result = try await PTZCapabilityDetector.detect(configuration: Self.camera, transport: transport)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 1, panMode: .continuous, tiltMode: .continuous, zoomMode: nil)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(1)])
        transport.capabilityError = .permissionDenied
        let discovery = PTZDiscovery { _, _ in transport }
        let denied = try await discovery.detect(configuration: Self.camera, password: "synthetic-test-password")
        XCTAssertEqual(denied, .unknown, "A permission error must not be treated as an absent firmware route.")
    }

    @MainActor
    func testMalformedCapabilityIsNotEquivalentToAnUnsupportedRoute() async throws {
        let transport = CapabilityTransport(channels: [], capability: Data("<html>Sign in</html>".utf8))
        transport.channelXML = Self.channelList(pan: true, tilt: true, zoom: false)
        let discovery = PTZDiscovery { _, _ in transport }
        let result = try await discovery.detect(configuration: Self.camera, password: "test")
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(transport.requests, [.channels, .capabilities(1)])
    }

    @MainActor
    func testMissingCollectionAndCapabilityCanUsePreciseConfigurationWithoutScanning() async throws {
        let transport = CapabilityTransport(channels: [], capability: Data())
        transport.collectionError = .unsupported
        transport.capabilityError = .unsupported
        transport.configurationXML = Data("<PTZChannel><id>4</id><videoInputID>4</videoInputID><panSupport>true</panSupport><tiltSupport>false</tiltSupport><zoomSupport>false</zoomSupport></PTZChannel>".utf8)
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 4)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 4, panMode: .continuous, tiltMode: nil, zoomMode: nil)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(4), .configuration(4)])
        transport.configurationXML = nil
        let unknown = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(unknown, .unknown, "Missing routes provide no evidence that a camera is physically fixed.")
    }

    @MainActor
    func testMissingAxisFlagsReadOnlyFallBackToTheSameChannelConfiguration() async throws {
        let transport = CapabilityTransport(channels: [4], capability: Data("<PTZChanelCap/>".utf8))
        transport.configurationXML = Data("<PTZChannel><id>4</id><enabled>true</enabled><videoInputID>4</videoInputID><panSupport>true</panSupport><tiltSupport>true</tiltSupport><zoomSupport>false</zoomSupport></PTZChannel>".utf8)
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 4)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(PTZCapabilities(channel: 4, panMode: .continuous, tiltMode: .continuous, zoomMode: nil)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(4), .configuration(4)])
        transport.configurationXML = Data("<PTZChannel><id>4</id><videoInputID>2</videoInputID><panSupport>true</panSupport></PTZChannel>".utf8)
        let mismatch = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(mismatch, .unknown, "Never offer controls for a different video input.")
    }

    @MainActor
    func testContinuousVetoSurvivesLateConfigurationFallbackAndKeepsTimedControl() async throws {
        let veto = Data("<PTZChanelCap><notSupportPTZContinuous>true</notSupportPTZContinuous></PTZChanelCap>".utf8)
        let transport = CapabilityTransport(channels: [1], capability: veto)
        transport.configurationXML = Data("<PTZChannel><id>1</id><panSupport>true</panSupport><tiltSupport>true</tiltSupport><zoomSupport>true</zoomSupport></PTZChannel>".utf8)
        let result = try await PTZCapabilityDetector.detect(configuration: Self.camera, transport: transport)
        XCTAssertEqual(result, .unsupported)
        let timedVeto = Data(String(decoding: Self.timedCapabilities, as: UTF8.self)
            .replacingOccurrences(of: "</PTZChanelCap>", with: "<notSupportPTZContinuous>true</notSupportPTZContinuous></PTZChanelCap>").utf8)
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(timedVeto, channel: 1),
                       .available(PTZCapabilities(channel: 1, panMode: .momentary, tiltMode: .momentary, zoomMode: .momentary, supportsContinuousStop: false)))
    }

    func testAbsoluteOrRelativeOnlyMeansKnownPTZWithUnsupportedControlMethod() throws {
        for space in ["AbsolutePanTiltPositionSpace", "RelativePanTiltSpace"] {
            let data = Data("<PTZChanelCap><\(space)><XRange><Min>0</Min><Max>1</Max></XRange></\(space)></PTZChanelCap>".utf8)
            XCTAssertEqual(try PTZCapabilityDocument.capabilities(data, channel: 1), .unsupported)
        }
    }

    func testExplicitAxisSupportEnablesContinuousAlongsidePositionSpacesUnlessVetoed() throws {
        let channel = try XCTUnwrap(PTZCapabilityDocument.channels(Self.channelList(pan: true, tilt: false, zoom: false)).first)
        for space in ["AbsolutePanTiltPositionSpace", "RelativePanTiltSpace"] {
            let xml = "<PTZChanelCap><\(space)><XRange><Min>0</Min><Max>1</Max></XRange></\(space)></PTZChanelCap>"
            XCTAssertEqual(try PTZCapabilityDocument.capabilities(Data(xml.utf8), channel: 1, configuration: channel),
                           .available(PTZCapabilities(channel: 1, panMode: .continuous, tiltMode: nil, zoomMode: nil)))
            let veto = xml.replacingOccurrences(of: "</PTZChanelCap>", with: "<notSupportPTZContinuous>true</notSupportPTZContinuous></PTZChanelCap>")
            XCTAssertEqual(try PTZCapabilityDocument.capabilities(Data(veto.utf8), channel: 1, configuration: channel), .unsupported)
        }
    }

    func testContinuousStopRequiresPositiveEvidenceEvenWhenTimedMovementIsAvailable() throws {
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(Self.timedCapabilities, channel: 1),
                       .available(Self.momentaryOnlyCapabilities(channel: 1)))
        let flags = try XCTUnwrap(PTZCapabilityDocument.channels(Self.channelList(pan: true, tilt: true, zoom: true)).first)
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(Self.timedCapabilities, channel: 1, configuration: flags),
                       .available(PTZCapabilities(channel: 1, panTilt: true, zoom: true)))
        let mixed = Data("<PTZChanelCap><MomentaryPanTiltSpace><XRange><Min>-1</Min><Max>1</Max></XRange></MomentaryPanTiltSpace><ContinuousZoomSpace><ZRange><Min>-1</Min><Max>1</Max></ZRange></ContinuousZoomSpace></PTZChanelCap>".utf8)
        XCTAssertEqual(try PTZCapabilityDocument.capabilities(mixed, channel: 1),
                       .available(PTZCapabilities(channel: 1, panMode: .momentary, tiltMode: nil, zoomMode: .continuous)))
    }

    @MainActor
    func testSingleUnmappedControlChannelMustNotBeGuessedForVideoChannelOne() async throws {
        let transport = CapabilityTransport(channels: [7], capability: Self.continuousCapabilities)
        let result = try await PTZCapabilityDetector.detect(configuration: Self.camera, transport: transport)
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(transport.requests, [.channels], "One listed PTZ channel is not proof that it belongs to video input one.")
        let explicit = CapabilityTransport(channels: [7], capability: Self.continuousCapabilities)
        let configured = CameraConfiguration(name: "Test", host: "camera.local", channel: 1, ptzEnabled: true, ptzChannel: 7)
        let selected = try await PTZCapabilityDetector.detect(configuration: configured, transport: explicit)
        XCTAssertEqual(selected, .available(PTZCapabilities(channel: 7, panMode: .continuous, tiltMode: .continuous, zoomMode: .continuous)))
        XCTAssertEqual(explicit.requests, [.channels, .capabilities(7)])
    }

    @MainActor
    func testMissingCollectionFallsBackOnlyToRequestedChannel() async throws {
        let transport = CapabilityTransport(channels: [], capability: Self.timedCapabilities)
        transport.collectionError = .unsupported
        let camera = CameraConfiguration(name: "Test", host: "camera.local", channel: 4)
        let result = try await PTZCapabilityDetector.detect(configuration: camera, transport: transport)
        XCTAssertEqual(result, .available(Self.momentaryOnlyCapabilities(channel: 4)))
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
    func testExplicitRetryBypassesCachedFailureButJoinsAnInFlightRead() async throws {
        let transport = CapabilityTransport(channels: [1], capability: Self.continuousCapabilities)
        transport.collectionError = .permissionDenied
        let discovery = PTZDiscovery { _, _ in transport }
        let failed = try await discovery.detect(configuration: Self.camera, password: "test")
        XCTAssertEqual(failed, .unknown)
        transport.collectionError = nil
        transport.blockCollection = true
        let first = Task { @MainActor in try await discovery.detect(configuration: Self.camera, password: "test", forceRefresh: true) }
        await transport.waitUntilBlocked()
        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return try await discovery.detect(configuration: Self.camera, password: "test", forceRefresh: true)
        }
        while !secondStarted { await Task.yield() }
        transport.releaseCollection()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .available(PTZCapabilities(channel: 1, panMode: .continuous, tiltMode: .continuous, zoomMode: .continuous)))
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(transport.requests, [.channels, .channels, .capabilities(1)])
        XCTAssertEqual(PTZDiscoveryResult.unknown.cacheDuration, 15)
        XCTAssertEqual(PTZDiscoveryResult.unavailable.cacheDuration, 15)
        XCTAssertEqual(PTZDiscoveryResult.unsupported.cacheDuration, 15)
        XCTAssertEqual(firstResult.cacheDuration, 300)
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
        XCTAssertEqual(result, .available(Self.momentaryOnlyCapabilities(channel: 1)))
        XCTAssertEqual(transport.requests, [.channels, .capabilities(1)])
    }

    private static var camera: CameraConfiguration { CameraConfiguration(name: "Test", host: "camera.local") }
    private static func momentaryOnlyCapabilities(channel: Int) -> PTZCapabilities {
        PTZCapabilities(channel: channel, panMode: .momentary, tiltMode: .momentary, zoomMode: .momentary, supportsContinuousStop: false)
    }
    private static func channelList(pan: Bool, tilt: Bool, zoom: Bool) -> Data {
        Data("<PTZChannelList xmlns=\"http://www.hikvision.com/ver20/XMLSchema\"><PTZChannel><id>1</id><enabled>true</enabled><videoInputID>1</videoInputID><panSupport>\(pan)</panSupport><tiltSupport>\(tilt)</tiltSupport><zoomSupport>\(zoom)</zoomSupport></PTZChannel></PTZChannelList>".utf8)
    }
    private static let continuousCapabilities = Data("""
    <PTZChanelCap xmlns="http://www.hikvision.com/ver20/XMLSchema" version="2.0">
      <ContinuousPanTiltSpace><XRange><Min>-1.000</Min><Max>1.000</Max></XRange><YRange><Min>-1.000</Min><Max>1.000</Max></YRange></ContinuousPanTiltSpace>
      <ContinuousZoomSpace><ZRange><Min>-1.000</Min><Max>1.000</Max></ZRange></ContinuousZoomSpace>
    </PTZChanelCap>
    """.utf8)
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
    var capabilityError: PTZError?
    var channelXML: Data?
    var configurationXML: Data?
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
        case .capabilities:
            if let capabilityError { throw capabilityError }
            return capability
        case .configuration:
            if let configurationXML { return configurationXML }
            throw PTZError.unsupported
        }
    }
    func waitUntilBlocked() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while blocked == nil && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(blocked)
    }
    func releaseCollection() { blocked?.resume(); blocked = nil }
}
