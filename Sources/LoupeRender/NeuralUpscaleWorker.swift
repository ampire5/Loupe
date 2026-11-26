import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import LoupeCore
import Metal
import os

public enum NeuralUpscaleError: LocalizedError {
    case incompatibleModel, unsupportedPhoto, tooLarge, tooManyTiles, pixelsUnavailable
    public var errorDescription: String? {
        switch self {
        case .incompatibleModel: "Model needs one fixed RGB image input and a 2× or 4× RGB image output"
        case .unsupportedPhoto: "Upscale requires an opaque SDR photo"
        case .tooLarge: "Upscale exceeds the memory limit for one photo"
        case .tooManyTiles: "Upscale needs too many tiles for this model"
        case .pixelsUnavailable: "Upscale could not read the image pixels"
        }
    }
}

/// A viewer can withdraw an in-flight request without waiting for the current prediction to finish.
public final class UpscaleCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { flag.withLock { $0 = true } }
    fileprivate func check() throws {
        if flag.withLock({ $0 }) { throw CancellationError() }
    }
}

/// Core ML and GPU readback can block, so they share a utility queue. The caller admits one request at a time.
public final class NeuralUpscaleWorker: @unchecked Sendable {
    public struct Result: Sendable {
        public let image: TiledImage
        public let scale: Int
        package var upscaleMilliseconds: Int?
        package var savedCopy: SavedUpscale?
        package var savedModel: String?
        package var saveError: String?
    }

    package struct SaveRequest: Sendable {
        package var copy: SavedUpscale
        package var orientation: ImageOrientation
        package var model: String

        package init(copy: SavedUpscale, orientation: ImageOrientation, model: String) {
            self.copy = copy
            self.orientation = orientation
            self.model = model
        }
    }

    private struct Loaded {
        let model: MLModel
        let input, output: String
        let width, height, scale: Int
    }

    private let queue = DispatchQueue(label: "Loupe neural upscale", qos: .utility)
    private let context: MetalContext
    private var loaded: (NeuralUpscaleModel, Loaded)?
    private var compiledURL: URL?
    private lazy var readbackQueue = context.device.makeCommandQueue()
    private lazy var readbackRenderer: TileRenderer = {
        let renderer = TileRenderer(context: context, pixelFormat: .bgra8Unorm_srgb)
        renderer.resample.pixelArtPercent = 100
        return renderer
    }()
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmap = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    public init(context: MetalContext = .shared) { self.context = context }

    deinit {
        if let compiledURL {
            queue.async { try? FileManager.default.removeItem(at: compiledURL) }
        }
    }

    public func process(_ source: TiledImage, model: NeuralUpscaleModel,
                        limit: Int, cancellation: UpscaleCancellation) async throws -> Result {
        try await process(source, model: model, limit: limit, cancellation: cancellation, saving: nil)
    }

    package func process(_ source: TiledImage, model: NeuralUpscaleModel,
                         limit: Int, cancellation: UpscaleCancellation, saving: SaveRequest?,
                         onRendered: (@MainActor @Sendable (Result) -> Void)? = nil) async throws -> Result {
        let (pixels, scale, started) = try await onQueue {
            let started = ContinuousClock.now
            let (pixels, scale) = try self.predict(source, model: model, limit: limit, cancellation: cancellation)
            return (pixels, scale, started)
        }
        try cancellation.check()
        let image = try await TiledImage.make(from: pixels, filter: .box, context: context)
        try cancellation.check()
        let elapsed = started.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        var result = Result(image: image, scale: scale, upscaleMilliseconds: Int(milliseconds.rounded()))
        if let saving {
            await onRendered?(result)
            do {
                try await onQueue {
                    try cancellation.check()
                    try saving.copy.write(pixels, orientation: saving.orientation, model: saving.model) {
                        try cancellation.check()
                    }
                }
                result.savedCopy = saving.copy
                result.savedModel = saving.model
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.saveError = error.localizedDescription
            }
        }
        return result
    }

    package func isPromoted(_ copy: SavedUpscale) async -> Bool {
        (try? await onQueue { copy.isPromoted }) ?? false
    }

    package func hasStored(_ copy: SavedUpscale) async -> Bool {
        (try? await onQueue { copy.exists && copy.modelIdentity != nil }) ?? false
    }

    package func stored(_ copy: SavedUpscale, originalSize: PixelSize, limit: Int,
                        matching model: String? = nil) async throws -> Result? {
        let decoded: (DecodedImage, Int, String?)? = try await onQueue {
            guard copy.exists, let metadata = copy.metadata, model == nil || metadata.model == model else { return nil }
            let data = try Data(contentsOf: copy.file, options: .mappedIfSafe)
            let decoder = ImageIOImageDecoder()
            let info = try decoder.probe(data)
            let originalOriented = metadata.orientation.orientedSize(originalSize)
            guard let scale = [2, 4].first(where: {
                info.pixelSize.width == originalOriented.width * $0 && info.pixelSize.height == originalOriented.height * $0
            }), let bytes = UpscaleGeometry.residentBytes(info.pixelSize), bytes <= limit else { return nil }
            let decoded = try decoder.decodeFull(data, info: info)
            let pixels = try ThumbnailMaker.orientedPixels(decoded, by: metadata.orientation.inverse)
            return (pixels, scale, metadata.model)
        }
        guard let (pixels, scale, identity) = decoded else { return nil }
        try Task.checkCancellation()
        let image = try await TiledImage.make(from: pixels, filter: .box, context: context)
        try Task.checkCancellation()
        return Result(image: image, scale: scale, savedCopy: copy, savedModel: identity)
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Swift.Result(catching: work)) }
        }
    }

    private func load(_ descriptor: NeuralUpscaleModel) throws -> Loaded {
        if let (key, model) = loaded, key == descriptor { return model }
        loaded = nil
        if let compiledURL { try? FileManager.default.removeItem(at: compiledURL) }
        compiledURL = nil
        let isPackage = descriptor.isPackage
        let url = try isPackage ? MLModel.compileModel(at: descriptor.url) : descriptor.url
        var keep = false
        defer { if isPackage && !keep { try? FileManager.default.removeItem(at: url) } }
        let config = MLModelConfiguration()
        config.computeUnits = descriptor.compute.units
        let model = try MLModel(contentsOf: url, configuration: config)
        let interface = try NeuralUpscaleModel.ImageInterface(model.modelDescription)
        guard descriptor.margin >= 0, descriptor.margin <= (min(interface.width, interface.height) - 1) / 2
        else { throw NeuralUpscaleError.incompatibleModel }

        let result = Loaded(model: model, input: interface.input, output: interface.output,
                            width: interface.width, height: interface.height, scale: interface.scale.rawValue)
        loaded = (descriptor, result)
        if isPackage { compiledURL = url; keep = true }
        return result
    }

    private func predict(_ source: TiledImage, model: NeuralUpscaleModel,
                         limit: Int, cancellation: UpscaleCancellation) throws -> (DecodedImage, Int) {
        try cancellation.check()
        guard !source.hasAlpha, !CGColorSpaceUsesITUR_2100TF(source.colorSpace), !CGColorSpaceUsesExtendedRange(source.colorSpace) else {
            throw NeuralUpscaleError.unsupportedPhoto
        }
        guard source.finestResidentLevel == 0 else { throw NeuralUpscaleError.pixelsUnavailable }
        let modelInfo = try load(model)
        try cancellation.check()
        let size = source.grid.imageSize
        let scale = modelInfo.scale
        let outputSize = PixelSize(width: size.width * scale, height: size.height * scale)
        guard let bytes = UpscaleGeometry.residentBytes(outputSize), bytes <= limit else {
            throw NeuralUpscaleError.tooLarge
        }

        let rows = UpscaleGeometry.windows(length: size.height, tile: modelInfo.height, margin: model.margin)
        let columns = UpscaleGeometry.windows(length: size.width, tile: modelInfo.width, margin: model.margin)
        // The measured 4K SPAN job uses 91 tiles. Bound pathological combinations of tiny tiles
        // and large context even when their final resolution fits in memory.
        guard rows.count * columns.count <= 256 else { throw NeuralUpscaleError.tooManyTiles }

        let pixels = try sourcePixels(source, size: size)
        try cancellation.check()
        let outputStride = DecodedImage.bytesPerRow(width: outputSize.width)
        let output = try PageAlignedBuffer(minimumLength: outputStride * outputSize.height)
        let input = try Self.pixelBuffer(width: modelInfo.width, height: modelInfo.height)
        let provider = try MLDictionaryFeatureProvider(dictionary: [modelInfo.input: MLFeatureValue(pixelBuffer: input)])
        for row in rows {
            for column in columns {
                try cancellation.check()
                try autoreleasepool {
                    try Self.fill(input, from: pixels, x: column.origin, y: row.origin)
                    let features = try modelInfo.model.prediction(from: provider)
                    guard let result = features.featureValue(for: modelInfo.output)?.imageBufferValue,
                          CVPixelBufferGetPixelFormatType(result) == kCVPixelFormatType_32BGRA,
                          CVPixelBufferGetWidth(result) == modelInfo.width * scale,
                          CVPixelBufferGetHeight(result) == modelInfo.height * scale,
                          CVPixelBufferLockBaseAddress(result, .readOnly) == kCVReturnSuccess
                    else { throw NeuralUpscaleError.incompatibleModel }
                    defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
                    guard let src = CVPixelBufferGetBaseAddress(result) else { throw NeuralUpscaleError.pixelsUnavailable }
                    let stride = CVPixelBufferGetBytesPerRow(result)
                    let x = column.content.lowerBound * scale
                    let y = row.content.lowerBound * scale
                    let offsetX = x - column.origin * scale
                    let offsetY = y - row.origin * scale
                    for line in 0..<(row.content.count * scale) {
                        let dest = output.bytes + (y + line) * outputStride + x * 4
                        memcpy(dest, src + (offsetY + line) * stride + offsetX * 4, column.content.count * scale * 4)
                    }
                }
            }
        }
        try cancellation.check()
        let result = DecodedImage(pixelSize: outputSize, bytesPerRow: outputStride, buffer: output,
                                  colorSpace: Self.srgb, hasAlphaChannel: false)
        return (try Self.convert(result, to: source.colorSpace), scale)
    }

    /// Draw at exactly one source pixel per target pixel, with no viewer effects. This uses the existing transfer
    /// curve and supports every source that already has a full-resolution Loupe pyramid.
    private func sourcePixels(_ image: TiledImage, size: PixelSize) throws -> DecodedImage {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                   width: size.width, height: size.height,
                                                                   mipmapped: false)
        descriptor.usage = [.renderTarget, .pixelFormatView]
        #if arch(x86_64)
        descriptor.storageMode = .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = context.device.makeTexture(descriptor: descriptor),
              let commands = readbackQueue?.makeCommandBuffer()
        else { throw NeuralUpscaleError.pixelsUnavailable }
        let dimensions = CGSize(width: size.width, height: size.height)
        let transform = ViewTransform(imageSize: dimensions, viewSize: dimensions, mode: .actual(1))
        readbackRenderer.encode(image: image, transform: transform, into: commands, target: texture)
        #if arch(x86_64)
        guard let blit = commands.makeBlitCommandEncoder() else { throw NeuralUpscaleError.pixelsUnavailable }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        #endif
        guard readbackRenderer.lastLevel == 0 else { throw NeuralUpscaleError.pixelsUnavailable }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw NeuralUpscaleError.pixelsUnavailable }
        let stride = DecodedImage.bytesPerRow(width: size.width)
        let buffer = try PageAlignedBuffer(minimumLength: stride * size.height)
        texture.getBytes(buffer.bytes, bytesPerRow: stride, from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
        let pixels = DecodedImage(pixelSize: size, bytesPerRow: stride, buffer: buffer,
                                  colorSpace: image.colorSpace, hasAlphaChannel: false)
        return try Self.convert(pixels, to: Self.srgb)
    }

    private static func convert(_ pixels: DecodedImage, to colorSpace: CGColorSpace) throws -> DecodedImage {
        guard pixels.colorSpace != colorSpace else { return pixels }
        let size = pixels.pixelSize
        let stride = pixels.bytesPerRow
        let output = try PageAlignedBuffer(minimumLength: stride * size.height)
        let retained = Unmanaged.passRetained(pixels.buffer)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels.buffer.bytes,
                                            size: stride * size.height, releaseData: { info, _, _ in
            if let info { Unmanaged<PageAlignedBuffer>.fromOpaque(info).release() }
        }) else {
            retained.release()
            throw NeuralUpscaleError.pixelsUnavailable
        }
        guard let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: stride, space: pixels.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric),
              let context = CGContext(data: output.bytes, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: stride, space: colorSpace, bitmapInfo: bitmap)
        else { throw NeuralUpscaleError.pixelsUnavailable }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return DecodedImage(pixelSize: size, bytesPerRow: stride, buffer: output,
                            colorSpace: colorSpace, hasAlphaChannel: false)
    }

    private static func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw NeuralUpscaleError.pixelsUnavailable }
        return buffer
    }

    private static func fill(_ tile: CVPixelBuffer, from pixels: DecodedImage, x: Int, y: Int) throws {
        guard CVPixelBufferLockBaseAddress(tile, []) == kCVReturnSuccess else { throw NeuralUpscaleError.pixelsUnavailable }
        defer { CVPixelBufferUnlockBaseAddress(tile, []) }
        guard let dest = CVPixelBufferGetBaseAddress(tile) else { throw NeuralUpscaleError.pixelsUnavailable }
        let width = CVPixelBufferGetWidth(tile), height = CVPixelBufferGetHeight(tile)
        let stride = CVPixelBufferGetBytesPerRow(tile)
        let count = min(width, pixels.pixelSize.width - x)
        for row in 0..<height {
            let src = pixels.buffer.bytes + min(y + row, pixels.pixelSize.height - 1) * pixels.bytesPerRow + x * 4
            let line = dest + row * stride
            memcpy(line, src, count * 4)
            if count < width {
                let edge = src.loadUnaligned(fromByteOffset: (count - 1) * 4, as: UInt32.self)
                line.assumingMemoryBound(to: UInt32.self).advanced(by: count).update(repeating: edge, count: width - count)
            }
        }
    }
}
