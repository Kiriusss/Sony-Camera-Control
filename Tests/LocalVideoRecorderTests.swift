import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(isMainThread: Bool, message: String)] = []

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((Thread.isMainThread, error.localizedDescription))
    }

    var values: [(isMainThread: Bool, message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    if !condition() { throw TestFailure(description: description) }
}

private func makeJPEG(width: Int, height: Int) throws -> Data {
    // Raw raster rows run from top to bottom: red/green above blue/yellow.
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let color: [UInt8]
            switch (x < width / 2, y < height / 2) {
            case (true, true): color = [255, 0, 0]
            case (false, true): color = [0, 255, 0]
            case (true, false): color = [0, 0, 255]
            case (false, false): color = [255, 255, 0]
            }
            let offset = (y * width + x) * 4
            for channel in 0..<3 { pixels[offset + channel] = color[channel] }
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw TestFailure(description: "Could not create JPEG destination")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "Could not encode test JPEG")
    return data as Data
}

private func finish(_ recorder: LocalVideoRecorder) async -> Result<URL, Error> {
    await withCheckedContinuation { continuation in
        recorder.finish { continuation.resume(returning: $0) }
    }
}

private func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> [Int] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw TestFailure(description: "Missing pixels") }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
}

@main
struct LocalVideoRecorderTests {
    static func main() async {
        do {
            let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory() + "LR1VideoTests", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let video = output.appendingPathComponent("quadrants.mov")
            let empty = output.appendingPathComponent("zero-frames.mov")
            let corrupt = output.appendingPathComponent("invalid-jpeg.mov")
            for url in [video, empty, corrupt] { try? FileManager.default.removeItem(at: url) }
            let jpeg = try makeJPEG(width: 320, height: 240)
            try jpeg.write(to: output.appendingPathComponent("quadrants.jpg"))
            let recorder = LocalVideoRecorder()
            let successProbe = FailureProbe()
            recorder.start(at: video, onFailure: successProbe.record)
            for frame in 0..<6 {
                recorder.append(jpeg: jpeg, timestamp: 1000 + Double(frame) * 0.2)
                // Exercise the real-time writer without flooding its bounded input.
                try await Task.sleep(nanoseconds: 220_000_000)
            }
            let result = await finish(recorder)
            guard case .success(let saved) = result else { throw TestFailure(description: "Recording failed: \(result)") }
            try require(successProbe.values.isEmpty, "Successful recording unexpectedly called onFailure")
            try require(saved == video, "Unexpected saved path")
            let asset = AVURLAsset(url: video)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TestFailure(description: "Missing video track") }
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            try require(size.width == 320 && size.height == 240, "Wrong dimensions: \(size)")
            try require(abs(duration - 1.2) < 0.04, "Wrong duration: \(duration)")
            let descriptions = try await track.load(.formatDescriptions)
            try require(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 } == true, "Video is not H.264")
            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(readerOutput)
            try require(reader.startReading(), "Could not decode MOV: \(String(describing: reader.error))")
            var frameCount = 0
            var times: [Double] = []
            var colors: [[Int]] = []
            while let sample = readerOutput.copyNextSampleBuffer() {
                frameCount += 1
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                if frameCount == 1, let buffer = CMSampleBufferGetImageBuffer(sample) {
                    colors = try [(80, 60), (240, 60), (80, 180), (240, 180)].map { try rgb(buffer, x: $0.0, y: $0.1) }
                }
            }
            try require(reader.status == .completed, "Decode failed: \(String(describing: reader.error))")
            try require(frameCount == 6, "Wrong frame count: \(frameCount)")
            let expected = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
            for (index, pair) in zip(colors, expected).enumerated() {
                try require(zip(pair.0, pair.1).allSatisfy { abs($0 - $1) < 45 }, "Frame quadrant \(index) has wrong color/orientation: \(colors)")
            }
            try require(colors.count == 4, "Missing first frame pixels")
            for (index, time) in times.enumerated() {
                try require(abs(time - Double(index) * 0.2) < 0.005, "Timestamp mismatch: \(times)")
            }
            print("PASS H.264 MOV: \(Int(size.width))×\(Int(size.height)), \(frameCount) frames, \(duration) s; first-frame quadrants \(colors); no failure callback")

            recorder.start(at: empty)
            let emptyResult = await finish(recorder)
            guard case .failure = emptyResult else { throw TestFailure(description: "Zero-frame recording should fail") }
            try require(!FileManager.default.fileExists(atPath: empty.path), "Zero-frame recording left a garbage file")
            print("PASS zero-frame recording: error returned, no output file")

            let failureProbe = FailureProbe()
            recorder.start(at: corrupt, onFailure: failureProbe.record)
            for frame in 0..<5 {
                recorder.append(jpeg: Data("not a jpeg".utf8), timestamp: Double(frame) * 0.2)
            }
            // Verify immediate notification before asking the writer to finish.
            let deadline = Date().addingTimeInterval(2)
            while failureProbe.values.isEmpty && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(failureProbe.values.count == 1, "Expected exactly one immediate failure callback, got \(failureProbe.values.count)")
            try require(failureProbe.values[0].isMainThread, "Failure callback did not run on the main thread")
            try require(!failureProbe.values[0].message.isEmpty, "Failure callback omitted its error")
            let invalidResult = await finish(recorder)
            guard case .failure = invalidResult else { throw TestFailure(description: "Invalid JPEG recording should fail") }
            try require(!FileManager.default.fileExists(atPath: corrupt.path), "Invalid JPEG recording left a garbage file")
            try require(failureProbe.values.count == 1, "Failure callback repeated during finish")
            print("PASS invalid JPEG: immediate main-thread failure callback exactly once, finish returned error, no output file")
            print("All LocalVideoRecorder offline tests passed. Artifacts: \(output.path)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
