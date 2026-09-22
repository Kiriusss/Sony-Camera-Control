import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Encodes SDK preview JPEG frames locally, using their actual arrival times.
final class LocalVideoRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.lr1.control.video", qos: .utility)
    private var destination: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp = CMTime.zero
    private var frameCount = 0
    private var frameWidth = 0
    private var frameHeight = 0
    private var failure: Error?
    private var failureHandler: ((Error) -> Void)?

    func start(at url: URL, onFailure: ((Error) -> Void)? = nil) {
        queue.sync {
            destination = url
            writer = nil
            input = nil
            adaptor = nil
            firstTimestamp = nil
            lastTimestamp = .zero
            frameCount = 0
            failure = nil
            failureHandler = onFailure
        }
    }

    func append(jpeg: Data, timestamp: TimeInterval) {
        queue.async { [self] in
            guard destination != nil, failure == nil else { return }
            do {
                guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw videoError("无法解码相机取景帧。")
                }
                if writer == nil { try prepare(image: image) }
                guard let writer, let input, let adaptor else { return }
                guard writer.status == .writing else { throw writer.error ?? videoError("视频编码器已停止。") }
                guard input.isReadyForMoreMediaData else { return }
                guard let pool = adaptor.pixelBufferPool else { throw videoError("无法分配视频帧缓冲区。") }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                    throw videoError("无法创建视频帧。")
                }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: frameWidth, height: frameHeight,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                    throw videoError("无法绘制视频帧。")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
                if firstTimestamp == nil { firstTimestamp = timestamp }
                let pts = CMTime(seconds: max(0, timestamp - firstTimestamp!), preferredTimescale: 600)
                guard frameCount == 0 || CMTimeCompare(pts, lastTimestamp) > 0 else { return }
                guard adaptor.append(buffer, withPresentationTime: pts) else {
                    throw writer.error ?? videoError("视频帧写入失败。")
                }
                lastTimestamp = pts
                frameCount += 1
            } catch {
                failure = error
                let handler = failureHandler
                failureHandler = nil
                RunLoop.main.perform(inModes: [.common]) { handler?(error) }
            }
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            let url = destination
            destination = nil
            guard failure == nil else {
                writer?.cancelWriting()
                if let url { try? FileManager.default.removeItem(at: url) }
                let error = failure!
                RunLoop.main.perform(inModes: [.common]) { completion(.failure(error)) }
                return
            }
            guard let writer, let input, let url, frameCount > 0 else {
                self.writer?.cancelWriting()
                if let url { try? FileManager.default.removeItem(at: url) }
                RunLoop.main.perform(inModes: [.common]) { completion(.failure(self.videoError("未收到取景画面，未生成视频。"))) }
                return
            }
            writer.endSession(atSourceTime: CMTimeAdd(lastTimestamp, CMTime(seconds: 0.2, preferredTimescale: 600)))
            input.markAsFinished()
            writer.finishWriting {
                let result: Result<URL, Error> = writer.status == .completed ? .success(url) : .failure(writer.error ?? self.videoError("视频保存失败。"))
                RunLoop.main.perform(inModes: [.common]) { completion(result) }
            }
        }
    }

    private func prepare(image: CGImage) throws {
        guard let destination else { return }
        frameWidth = image.width - image.width % 2
        frameHeight = image.height - image.height % 2
        guard frameWidth > 0, frameHeight > 0 else { throw videoError("取景尺寸无效。") }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: frameWidth,
            AVVideoHeightKey: frameHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(1_500_000, frameWidth * frameHeight * 4), AVVideoExpectedSourceFrameRateKey: 5]
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: frameWidth,
            kCVPixelBufferHeightKey as String: frameHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw videoError("系统不支持当前取景尺寸的视频编码。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? videoError("无法创建本地视频。") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func videoError(_ message: String) -> NSError {
        NSError(domain: "LR1.LocalVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
