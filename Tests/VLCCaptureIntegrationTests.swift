import AVFoundation
import CoreVideo
import UIKit
import XCTest
@testable import Luma

/// Exercises the bundled MobileVLCKit binary, renderer, callbacks and actual
/// capture files. The only input is a generated local test pattern, never a
/// camera, external download, network service, or user media.
final class VLCCaptureIntegrationTests: XCTestCase {
    @MainActor
    func testRealVLCPreviewDoesNotInterfereWithSnapshotAndTwoPlayableRecordings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("local-pattern.mp4")
        try await generatePattern(at: movie)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                 "The hosted test requires a UIWindowScene for real VLC video output.")
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let viewport = ZoomableCameraVideoView()
        viewport.frame = controller.view.bounds
        viewport.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(viewport)
        viewport.layoutIfNeeded()
        viewport.configure(enabled: true, resetID: UUID())
        let video = viewport.videoView
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let library = MediaLibrary.shared
        let previousIDs = Set(library.items.map(\.id))
        let probe = CaptureProbe()
        let session = VLCPlaybackSession(url: movie, useTCP: false)
        session.onEvent = { event in
            probe.observe(event)
            switch event {
            case .videoPlaying: probe.videoStarted = true
            case .firstFrame: probe.firstFrameReceived = true
            case .failed: probe.failure = "VLC failed to open the generated local H.264 test pattern."
            default: break
            }
        }
        session.onCaptureEvent = { event in
            switch event {
            case .recordingStarted: probe.recordingStarted = true
            case .saved(.snapshot): probe.snapshotSaved = true
            case .saved(.recording): probe.recordingSaved = true
            case .failed(let message): probe.failure = "The real VLC capture failed: \(message)"
            default: break
            }
        }

        do {
            probe.phase = "initial playback"
            session.start(on: video, muted: true, aspectFill: false)
            try await waitFor("VLC did not confirm a decoded or displayed video frame", probe: probe) { probe.firstFrameReceived }
            XCTAssertTrue(probe.videoStarted, "First-frame evidence must also publish the normal video-playing event for local library consumers.")
            viewport.setZoomScale(2, animated: false)
            probe.phase = "preview and queued manual snapshot"
            let previewCamera = CameraConfiguration(name: "Synthetic preview", host: "192.0.2.90")
            let thumbnails = CameraThumbnailStore(directory: directory.appendingPathComponent("thumbnails"),
                                                  cameras: [previewCamera])
            let preparedCapture = await thumbnails.prepareCapture(for: previewCamera)
            let previewCapture = try XCTUnwrap(preparedCapture, "The isolated thumbnail store must provide a capture destination.")
            session.capturePreview(at: previewCapture.fileURL) { success in
                probe.previewCompletions += 1
                probe.previewSucceeded = success
                if !success {
                    let exists = FileManager.default.fileExists(atPath: previewCapture.fileURL.path)
                    let decodes = UIImage(contentsOfFile: previewCapture.fileURL.path) != nil
                    probe.failure = "VLC could not capture the separate camera-card preview. fileExists=\(exists), decodable=\(decodes)"
                }
            }
            // This is intentionally immediate: the automatic snapshot owns the
            // SDK's single snapshot destination while a user requests a capture.
            session.captureSnapshot()
            try await waitFor("Preview and the queued user snapshot did not both complete", probe: probe) {
                probe.previewSucceeded == true && probe.snapshotSaved
            }
            let preview = try XCTUnwrap(UIImage(contentsOfFile: previewCapture.fileURL.path), "Preview must contain a real decodable image.")
            XCTAssertEqual(preview.size.width / preview.size.height, 16.0 / 9.0, accuracy: 0.02)
            XCTAssertEqual(probe.previewCompletions, 1)
            await thumbnails.save(previewCapture)
            let cachedData = await thumbnails.imageData(for: previewCamera)
            let cachedPreview = try XCTUnwrap(cachedData.flatMap { UIImage(data: $0) },
                                             "The real VLC frame must survive the local thumbnail store's decode and persistence path.")
            XCTAssertEqual(cachedPreview.size.width / cachedPreview.size.height, 16.0 / 9.0, accuracy: 0.02)
            XCTAssertLessThanOrEqual(max(cachedPreview.size.width, cachedPreview.size.height), 640)
            for recordingNumber in 1...2 {
                probe.phase = "recording \(recordingNumber) start"
                probe.recordingStarted = false
                probe.recordingSaved = false
                session.toggleRecording()
                try await waitFor("VLC did not confirm recording \(recordingNumber) started", probe: probe) { probe.recordingStarted }
                try await Task.sleep(for: .seconds(3))
                probe.phase = "recording \(recordingNumber) finalization"
                session.toggleRecording()
                try await waitFor("VLC recording \(recordingNumber) completion did not produce a library item", probe: probe, seconds: 18) { probe.recordingSaved }
            }
            probe.phase = "initial session retirement"
            await withCheckedContinuation { continuation in
                session.retire { continuation.resume() }
            }

            let captures = library.items.filter { !previousIDs.contains($0.id) }
            XCTAssertEqual(captures.filter { $0.kind == .snapshot }.count, 1,
                           "The camera-card preview must not appear as a user snapshot in the media library.")
            XCTAssertEqual(captures.filter { $0.kind == .recording }.count, 2)
            XCTAssertEqual(probe.previewCompletions, 1, "Manual SDK snapshot callbacks must never be mistaken for another preview.")
            for item in captures {
                let url = try XCTUnwrap(library.fileURL(for: item))
                let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                XCTAssertGreaterThan(try XCTUnwrap(bytes).int64Value, 0, "A completed SDK callback must leave a nonempty file.")
                if item.kind == .recording {
                    probe.phase = "finalized recording replay"
                    try await verifyRecordingPlayback(url, on: video)
                }
                try library.delete(item)
            }
        } catch {
            recordFailure(error, probe: probe, name: "vlc-capture-failure")
            await withCheckedContinuation { continuation in
                session.retire { continuation.resume() }
            }
            for item in library.items where !previousIDs.contains(item.id) { try? library.delete(item) }
            throw error
        }
    }

    @MainActor
    private func verifyRecordingPlayback(_ url: URL, on view: UIView) async throws {
        let probe = CaptureProbe()
        let playback = VLCPlaybackSession(url: url, useTCP: false)
        playback.onEvent = { event in
            probe.observe(event)
            switch event {
            case .videoPlaying: probe.videoStarted = true
            case .firstFrame: probe.firstFrameReceived = true
            case .failed: probe.failure = "VLC could not replay its finalized local recording."
            default: break
            }
        }
        do {
            probe.phase = "finalized recording replay"
            playback.start(on: view, muted: true, aspectFill: false)
            try await waitFor("The finalized recording did not decode or display a video frame when replayed", probe: probe) { probe.firstFrameReceived }
            XCTAssertTrue(probe.videoStarted, "A replay's first frame must also publish the normal video-playing event.")
            await withCheckedContinuation { continuation in playback.retire { continuation.resume() } }
        } catch {
            recordFailure(error, probe: probe, name: "vlc-recording-replay-failure")
            await withCheckedContinuation { continuation in playback.retire { continuation.resume() } }
            throw error
        }
    }

    @MainActor
    private func recordFailure(_ error: Error, probe: CaptureProbe, name: String) {
        let message = "VLC integration failure during \(probe.phase): \(error.localizedDescription)"
        let attachment = XCTAttachment(string: message + "\nfirstFrame=\(probe.firstFrameReceived), videoPlaying=\(probe.videoStarted), previewSucceeded=\(String(describing: probe.previewSucceeded)), previewCompletions=\(probe.previewCompletions), snapshotSaved=\(probe.snapshotSaved), recordingStarted=\(probe.recordingStarted), recordingSaved=\(probe.recordingSaved), callbackFailure=\(probe.failure ?? "none")\nevents=\(probe.events.joined(separator: ", "))")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Record before awaiting cleanup: a shutdown/framework exception must
        // not replace the useful failure with XCTest's generic deinit error.
        XCTFail(message)
    }

    @MainActor
    private func waitFor(_ description: String, probe: CaptureProbe, seconds: Int = 12,
                         condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            if let failure = probe.failure { throw IntegrationFailure.failed(failure) }
            guard ContinuousClock.now < deadline else { throw IntegrationFailure.failed(description) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    private func generatePattern(at url: URL) async throws {
        let width = 160
        let height = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10,
                                              AVVideoAverageBitRateKey: 100_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw IntegrationFailure.failed("AVAssetWriter cannot encode the test pattern.") }
        writer.add(input)
        guard writer.startWriting() else { throw IntegrationFailure.failed("AVAssetWriter could not start the local fixture.") }
        writer.startSession(atSourceTime: .zero)
        let encodingDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        defer { if writer.status == .writing { writer.cancelWriting() } }
        // Allow slow CI simulators enough playback time for both captures.
        for frame in 0..<600 {
            guard ContinuousClock.now < encodingDeadline else {
                throw IntegrationFailure.failed("Local fixture encoding exceeded its deadline.")
            }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < encodingDeadline else {
                    writer.cancelWriting()
                    throw IntegrationFailure.failed("Local fixture encoding stalled.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard result == kCVReturnSuccess, let buffer else { throw IntegrationFailure.failed("Unable to allocate the local test pattern.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            guard let context else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw IntegrationFailure.failed("Unable to draw the local test pattern.")
            }
            context.setFillColor(UIColor(red: CGFloat(frame % 100) / 100, green: 0.25, blue: 0.75, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: frame % 140, y: 30, width: 20, height: 20))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                writer.cancelWriting()
                throw IntegrationFailure.failed("AVAssetWriter rejected a generated video frame.")
            }
        }
        input.markAsFinished()
        writer.finishWriting(completionHandler: {})
        while writer.status == .writing {
            guard ContinuousClock.now < encodingDeadline else {
                throw IntegrationFailure.failed("Local fixture finalization exceeded its deadline.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard writer.status == .completed else { throw IntegrationFailure.failed("The generated local test pattern was not finalized.") }
    }
}

@MainActor
private final class CaptureProbe {
    var phase = "preparation"
    var firstFrameReceived = false
    var videoStarted = false
    var snapshotSaved = false
    var previewSucceeded: Bool?
    var previewCompletions = 0
    var recordingStarted = false
    var recordingSaved = false
    var failure: String?
    var events: [String] = []

    func observe(_ event: VLCPlaybackEvent) {
        let name: String
        switch event {
        case .opening: name = "opening"
        case .buffering: name = "buffering"
        case .videoPlaying: name = "videoPlaying"
        case .firstFrame: name = "firstFrame"
        case .routeUnavailable: name = "routeUnavailable"
        case .routeConflict: name = "routeConflict"
        case .failed: name = "failed"
        case .ended: name = "ended"
        case .snapshotSaved: name = "snapshotSaved"
        case .recordingStarted: name = "recordingStarted"
        case .recordingStopped: name = "recordingStopped"
        }
        // Fixed labels only; no native paths, URLs, or media metadata.
        if events.last != name && events.count < 40 { events.append(name) }
    }
}

private enum IntegrationFailure: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}
