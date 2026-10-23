import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import LoupeCore
import LoupeRender
import Metal

/// The replay's synthetic screen: each frame draws what show-blurry=no would have on screen at that moment with
/// `TileRenderer` into a 1920×1080 `bgra8Unorm_srgb` target, reads it back into a pixel buffer, draws a CoreText
/// overlay over it and appends it to an H.264 .mov or .mp4 by extension (30 fps on the replay's wall-clock timeline, at most 60 s).
/// Used from the sampler thread only.
final class ReplayVideo: @unchecked Sendable {
    static let size = PixelSize(width: 1920, height: 1080)
    static let maxFrames = 60 * 30
    /// 5 Mbit/s keeps a 60 s video under ~40 MB.
    static let bitRate = 5_000_000

    struct Summary {
        let path: String
        let frames: Int
        let duration: Double
        let bytes: Int
        let renderP50, renderP99, renderMax: Double
    }

    private let url: URL
    private let screen: PixelSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let renderer: TileRenderer
    private let target: MTLTexture
    private let font: CTFont
    private var appended = 0
    private var dropped = 0
    private var lastIndex = -1
    private var render = Samples()

    init(url: URL, screen: PixelSize) throws {
        self.url = url
        self.screen = screen
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.size.width,
            AVVideoHeightKey: Self.size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Self.bitRate],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.size.width,
            kCVPixelBufferHeightKey as String: Self.size.height,
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let context = MetalContext.shared
        renderer = TileRenderer(context: context, pixelFormat: .bgra8Unorm_srgb)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: Self.size.width,
                                                         height: Self.size.height, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: d) else { throw CocoaError(.fileWriteUnknown) }
        target = texture
        font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
    }

    /// Renders and appends frame `index` (30 fps timeline) for `state`.
    func frame(_ state: FrameState, index: Int, ram: Int, gpu: Int) {
        guard index < Self.maxFrames, index > lastIndex else { return }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            dropped += 1
            return
        }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { dropped += 1; return }

        // GPU: the shown pyramid at the script's zoom, scaled from the screen to the video.
        let context = MetalContext.shared
        let started = ContinuousClock.now
        guard let commands = context.queue.makeCommandBuffer() else { dropped += 1; return }
        let image = state.shown?.failure == nil ? state.shown?.pyramid : nil
        var transform = ViewTransform(imageSize: .zero, viewSize: CGSize(width: Self.size.width, height: Self.size.height))
        var orientation = ImageOrientation.up
        if let shown = state.shown, let info = shown.info {
            // As the viewer lays it out (`exif-orientation` at its default): oriented, a seeded thumbnail already
            // turned.
            orientation = info.drawOrientation(applying: true, seeded: shown.isSeededOnly)
            let size = CGSize(width: info.orientedSize.width, height: info.orientedSize.height)
            let view = CGSize(width: Self.size.width, height: Self.size.height)
            switch state.zoom {
            case .fit: transform = ViewTransform(imageSize: size, viewSize: view, mode: .fit)
            case .actual:
                transform = ViewTransform(imageSize: size, viewSize: view,
                                          mode: .actual(Double(Self.size.width) / Double(screen.width)))
            }
        }
        renderer.encode(image: image, transform: transform, orientation: orientation, into: commands, target: target)
        commands.commit()
        commands.waitUntilCompleted()
        render.add(msSince(started))

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            target.getBytes(base, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, Self.size.width, Self.size.height), mipmapLevel: 0)
            drawOverlay(state, ram: ram, gpu: gpu, base: base, bytesPerRow: bytesPerRow)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)) {
            appended += 1
            lastIndex = index
        } else {
            dropped += 1
        }
    }

    private func drawOverlay(_ state: FrameState, ram: Int, gpu: Int, base: UnsafeMutableRawPointer, bytesPerRow: Int) {
        guard let cg = CGContext(data: base, width: Self.size.width, height: Self.size.height, bitsPerComponent: 8,
                                 bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let sinceStep = msSince(state.stepStart)
        let gb = { (b: Int) in String(format: "%.2f GB", Double(b) / 1_073_741_824) }
        var lines = ["\(state.script)  \(state.zoom.rawValue)  step \(state.step)/\(state.stepCount)  "
                     + "+\(Int(sinceStep)) ms",
                     "cache \(state.usedBytes >> 20) / \(state.limitBytes >> 20) MB   "
                         + (state.graphicsLimitBytes.map { "graphics \(state.graphicsUsedBytes >> 20) / \($0 >> 20) MB   " } ?? "")
                         + "RAM \(gb(ram))   GPU \(gb(gpu))"]
        if let shown = state.shown {
            let finest = shown.pyramid?.finestResidentLevel.map { "L\($0)" } ?? "-"
            let st = shown.failure != nil ? "failed" : shown.state.map { "\($0)" } ?? "-"
            lines.insert("screen: \(shown.url.lastPathComponent)  [shown \(st), resident now \(finest)]", at: 1)
        } else {
            lines.insert("screen: (nothing yet)", at: 1)
        }
        let waiting = state.shown?.url.lastPathComponent != state.currentName
        if waiting { lines.insert("Loading… \(state.currentName)", at: 2) }

        let lineHeight = 32.0, pad = 14.0
        let boxHeight = Double(lines.count) * lineHeight + pad * 2
        let top = Double(Self.size.height) - 20
        cg.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
        cg.fill(CGRect(x: 20, y: top - boxHeight, width: 1100, height: boxHeight))
        for (i, text) in lines.enumerated() {
            let colour = waiting && i == 2 ? CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            cg.textPosition = CGPoint(x: 20 + pad, y: top - pad - Double(i + 1) * lineHeight + 8)
            CTLineDraw(line, cg)
        }
    }

    /// Closes the file and reads it back with AVFoundation (duration, frame count) as a check.
    func finish() async -> Summary {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { warn("video \(url.path): \(writer.error.map { "\($0)" } ?? "not completed")") }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if dropped > 0 { warn("video \(url.lastPathComponent): \(dropped) frames dropped (writer busy)") }
        return Summary(path: url.path, frames: appended, duration: duration, bytes: bytes,
                       renderP50: render.median ?? 0, renderP99: render.percentile(99) ?? 0,
                       renderMax: render.percentile(100) ?? 0)
    }
}
