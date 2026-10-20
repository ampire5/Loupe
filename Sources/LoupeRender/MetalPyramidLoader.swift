import CoreGraphics
import os
import LoupeCore

/// `pyramid-filter` as the loader reads it: set by the app at launch and on every config reload, read at each upload,
/// so a change applies to photos uploaded after it (pyramids already built stay as they are). A lock rather than an
/// actor: the loader reads it synchronously inside its async upload.
public final class PyramidFilterSetting: Sendable {
    private let lock: OSAllocatedUnfairLock<PyramidFilter>

    public init(_ value: PyramidFilter = Config().pyramidFilter) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    public var value: PyramidFilter { lock.withLock { $0 } }

    public func set(_ value: PyramidFilter) {
        lock.withLock { $0 = value }
    }
}

/// The app's `PyramidLoader`: cache pyramids are `TiledImage`s on `context`'s device, built with `filter`'s value at
/// the time of each upload.
public struct MetalPyramidLoader: PyramidLoader {
    public typealias Pyramid = TiledImage
    private let context: MetalContext
    private let filter: PyramidFilterSetting

    public init(context: MetalContext = .shared, filter: PyramidFilterSetting = PyramidFilterSetting()) {
        self.context = context
        self.filter = filter
    }

    public func makePyramid(grid: TileGrid, colorSpace: CGColorSpace) -> TiledImage {
        TiledImage.empty(grid: grid, colorSpace: colorSpace)
    }

    public func upload(_ image: LevelImage, into pyramid: TiledImage) async throws {
        try await pyramid.upload(image, filter: filter.value, context: context)
    }

    public func evict(finerThan level: Int, of pyramid: TiledImage) {
        pyramid.evict(finerThan: level)
    }

    public func finestResidentLevel(of pyramid: TiledImage) -> Int? {
        pyramid.finestResidentLevel
    }
}
