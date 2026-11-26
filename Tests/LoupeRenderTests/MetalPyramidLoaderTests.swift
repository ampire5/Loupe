import CoreGraphics
import Foundation
import Metal
import LoupeCore
import Testing
@testable import LoupeRender

@Test func loaderUploadsAndEvicts() async throws {
    let loader = MetalPyramidLoader()
    let grid = TileGrid(imageSize: PixelSize(width: 2200, height: 1400))
    let pyramid = loader.makePyramid(grid: grid, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    #expect(loader.finestResidentLevel(of: pyramid) == nil)

    let l2 = grid.levelSize(2)
    try await loader.upload(LevelImage(image: TestImages.synthetic(l2.width, l2.height), level: 2), into: pyramid)
    #expect(loader.finestResidentLevel(of: pyramid) == 2)

    try await loader.upload(LevelImage(image: TestImages.synthetic(2200, 1400), level: 0), into: pyramid)
    #expect(loader.finestResidentLevel(of: pyramid) == 0)

    loader.evict(finerThan: 2, of: pyramid)
    #expect(loader.finestResidentLevel(of: pyramid) == 2)
}

@Test func loaderReadsPyramidFilterAtUpload() async throws {
    // pyramid-filter applies to uploads after a reload: the loader reads the setting at each upload, not at init.
    let setting = PyramidFilterSetting(.box)
    let loader = MetalPyramidLoader(filter: setting)
    setting.set(.lanczos3)
    #expect(setting.value == .lanczos3)
    let image = TestImages.synthetic(1100, 700, pixel: TestImages.noiseAndEdges)
    let pyramid = loader.makePyramid(grid: TileGrid(imageSize: image.pixelSize), colorSpace: image.colorSpace)
    try await loader.upload(LevelImage(image: image, level: 0), into: pyramid)
    let lanczos = try await TiledImage.make(from: image, filter: .lanczos3)
    let box = try await TiledImage.make(from: image, filter: .box)
    let got = try await TestImages.readSlice(pyramid.levels[1], slice: 0)
    #expect(got == (try await TestImages.readSlice(lanczos.levels[1], slice: 0)))
    #expect(got != (try await TestImages.readSlice(box.levels[1], slice: 0)))
}

@Test func cacheCountsAllocatedTextureBytes() async throws {
    let loader = MetalPyramidLoader()
    var limits = CacheLimits()
    limits.graphicsMemory = nil
    let cache = ImageCache(loader: loader, limits: limits)
    let image = TestImages.synthetic(1100, 700)
    let file = URL(fileURLWithPath: "/photo.jpg")
    let info = ImageInfo(pixelSize: image.pixelSize, typeIdentifier: "public.jpeg",
                         isProgressive: false, fileSize: 0, colorSpaceName: nil)
    await cache.seed(file, info: info, level: LevelImage(image: image, level: 0))
    let pyramid = try #require(await cache.entry(file)?.pyramid)
    let allocated = pyramid.levels.reduce(0) { $0 + $1.allocatedSize }
    #expect(await cache.stats().usedBytes == allocated)
}

@Test func cacheEvictionReleasesTexturesHeldByABorrower() async throws {
    var limits = CacheLimits()
    limits.graphicsMemory = nil
    let cache = ImageCache(loader: MetalPyramidLoader(), limits: limits)
    let image = TestImages.synthetic(600, 400)
    let file = URL(fileURLWithPath: "/photo.jpg")
    let info = ImageInfo(pixelSize: image.pixelSize, typeIdentifier: "public.jpeg",
                         isProgressive: false, fileSize: 0, colorSpaceName: nil)
    await cache.seed(file, info: info, level: LevelImage(image: image, level: 0))
    let borrowed = try #require(await cache.entry(file)?.pyramid)

    limits.memory = 0
    await cache.setLimits(limits)

    #expect(await cache.stats().usedBytes == 0)
    #expect(borrowed.finestResidentLevel == nil)
}
