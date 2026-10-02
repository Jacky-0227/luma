import AVFoundation
import CoreVideo
import UIKit

/// Encodes a small moving test pattern with the platform encoder, then reads
/// its compressed NAL units. No downloaded media, fixture service, or camera
/// data is needed. The loopback server repeatedly transmits these frames.
struct RTSPH264Pattern: Sendable {
    let sps: Data
    let pps: Data
    let frames: [[Data]]

    @MainActor
    static func make() async throws -> RTSPH264Pattern {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("luma-rtsp-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let width = 160, height = 96
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10,
                                              AVVideoAllowFrameReorderingKey: false,
                                              AVVideoAverageBitRateKey: 120_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw RTSPFixtureError.failed("RTSP fixture encoder input is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw RTSPFixtureError.failed("RTSP fixture encoder could not start.") }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw RTSPFixtureError.failed("RTSP fixture encoding stalled.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw RTSPFixtureError.failed("RTSP fixture pixel buffer allocation failed.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw RTSPFixtureError.failed("RTSP fixture drawing context is unavailable.")
            }
            context.setFillColor(UIColor(red: 0.1, green: CGFloat(frame % 10) / 15, blue: 0.7, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: (frame * 4) % 140, y: 35, width: 20, height: 20))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw RTSPFixtureError.failed("RTSP fixture frame encoding failed.")
            }
        }
        input.markAsFinished()
        writer.finishWriting(completionHandler: {})
        while writer.status == .writing {
            guard ContinuousClock.now < deadline else { throw RTSPFixtureError.failed("RTSP fixture finalization timed out.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard writer.status == .completed else { throw RTSPFixtureError.failed("RTSP fixture encoder did not finish.") }

        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RTSPFixtureError.failed("RTSP fixture has no encoded video track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw RTSPFixtureError.failed("RTSP fixture compressed reader is unavailable.") }
        reader.add(output)
        guard reader.startReading() else { throw RTSPFixtureError.failed("RTSP fixture compressed reader could not start.") }
        defer { reader.cancelReading() }
        var sps = Data(), pps = Data()
        var frames: [[Data]] = []
        while let sample = output.copyNextSampleBuffer() {
            // Compressed AVAssetReader output may contain marker-only buffers
            // (stream/edit boundaries). They carry no media sample or block.
            // Only actual samples belong in the RTP fixture's frame sequence.
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { continue }
            guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
                throw RTSPFixtureError.failed("RTSP fixture media sample has no format or data block (samples: \(sampleCount)).")
            }
            var headerLength: Int32 = 0
            if sps.isEmpty {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength) == noErr,
                      let spsPointer = pointer, headerLength == 4 else {
                    throw RTSPFixtureError.failed("RTSP fixture H.264 sequence parameters are invalid.")
                }
                sps = Data(bytes: spsPointer, count: size)
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let ppsPointer = pointer else {
                    throw RTSPFixtureError.failed("RTSP fixture H.264 picture parameters are invalid.")
                }
                pps = Data(bytes: ppsPointer, count: size)
            }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            let copyResult = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard copyResult == noErr else { throw RTSPFixtureError.failed("RTSP fixture sample copy failed.") }
            var units: [Data] = frames.isEmpty ? [sps, pps] : []
            var offset = 0
            while offset + 4 <= bytes.count {
                let count = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4
                guard count > 0, offset + count <= bytes.count else { throw RTSPFixtureError.failed("RTSP fixture NAL length is invalid.") }
                units.append(Data(bytes[offset..<offset + count]))
                offset += count
            }
            guard offset == bytes.count, !units.isEmpty else { throw RTSPFixtureError.failed("RTSP fixture frame is truncated.") }
            frames.append(units)
        }
        guard reader.status == .completed, !sps.isEmpty, !pps.isEmpty, frames.count == 30 else {
            throw RTSPFixtureError.failed("RTSP fixture did not yield all 30 encoded H.264 frames (received \(frames.count)).")
        }
        return RTSPH264Pattern(sps: sps, pps: pps, frames: frames)
    }
}
