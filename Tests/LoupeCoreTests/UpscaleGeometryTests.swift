import Testing
@testable import LoupeCore

struct UpscaleGeometryTests {
    @Test func partitionsKeepContextAndCoverEachPixelOnce() throws {
        for length in [1, 255, 384, 385, 720, 1920, 3072] {
            let parts = UpscaleGeometry.windows(length: length, tile: 384, margin: 40)
            #expect(parts.flatMap { Array($0.content) } == Array(0..<length))
            for part in parts {
                #expect(part.origin <= part.content.lowerBound)
                #expect(part.origin + 384 >= part.content.upperBound)
                if part.content.lowerBound > 0 { #expect(part.content.lowerBound - part.origin >= 40) }
                if part.content.upperBound < length { #expect(part.origin + 384 - part.content.upperBound >= 40) }
            }
        }
        #expect(UpscaleGeometry.windows(length: 720, tile: 384, margin: 40).count == 3)
        #expect(UpscaleGeometry.windows(length: 720, tile: 384, margin: 192).isEmpty)
    }

    @Test func estimatesResidentTextureBytesAndRejectsOverlargeImages() {
        #expect(UpscaleGeometry.residentBytes(PixelSize(width: 512, height: 512)) == 528 * 528 * 4)
        #expect(UpscaleGeometry.residentBytes(PixelSize(width: 513, height: 512)) == 3 * 528 * 528 * 4)
        #expect(UpscaleGeometry.residentBytes(PixelSize(width: 100_000, height: 100_000)) == nil)
    }

    @Test func leastRecentlyUsedAndPressureTrim() {
        var cache = UpscaleResultCache<String, Int>()
        cache.insert(1, key: "a", bytes: 30, limit: 60)
        cache.insert(2, key: "b", bytes: 30, limit: 60)
        #expect(cache.value(for: "a") == 1)
        cache.insert(3, key: "c", bytes: 30, limit: 60)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        cache.trim(to: 30)
        #expect(cache.value(for: "c") == nil)
        #expect(cache.bytes == 30)
        cache.insert(4, key: "a", bytes: 20, limit: 30)
        #expect(cache.bytes == 20)
        cache.insert(5, key: "oversize", bytes: 31, limit: 30)
        #expect(cache.bytes == 20)
    }
}
