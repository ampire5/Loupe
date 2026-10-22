import Foundation
import Testing
@testable import LoupeCore

/// The swap is the same however many bands run it, every row (an odd height, rows padded) included.
@Test(arguments: [1, 2, 5, 16])
func swapIsTheSameOnAnyWorkers(workers: Int) throws {
    let width = 3, height = 7, bytesPerRow = 16
    var bytes = [UInt8](repeating: 0xEE, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let o = y * bytesPerRow + x * 4
            bytes[o] = UInt8(x); bytes[o + 1] = UInt8(y); bytes[o + 2] = UInt8(10 * x + y); bytes[o + 3] = 255
        }
    }
    bytes.withUnsafeMutableBytes { raw in
        RGBAToBGRA.convert(raw.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow, premultiply: false,
                           workers: workers)
    }
    for y in 0..<height {
        for x in 0..<width {
            let o = y * bytesPerRow + x * 4
            #expect(bytes[o] == UInt8(10 * x + y) && bytes[o + 1] == UInt8(y) && bytes[o + 2] == UInt8(x) && bytes[o + 3] == 255)
        }
        #expect(bytes[(y * bytesPerRow + width * 4)..<((y + 1) * bytesPerRow)].allSatisfy { $0 == 0xEE })
    }
}
