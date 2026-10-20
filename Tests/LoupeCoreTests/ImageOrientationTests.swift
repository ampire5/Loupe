import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LoupeCore

/// Which pattern colour a pixel is nearest to, as an index into `TestJPEGs.patternColors`.
private func nearestColor(_ r: Int, _ g: Int, _ b: Int) -> Int {
    TestJPEGs.patternColors.indices.min { lhs, rhs in
        func distance(_ c: (r: Int, g: Int, b: Int)) -> Int { (c.r - r) * (c.r - r) + (c.g - g) * (c.g - g) + (c.b - b) * (c.b - b) }
        return distance(TestJPEGs.patternColors[lhs]) < distance(TestJPEGs.patternColors[rhs])
    }!
}

/// The pattern's cell colours as CoreGraphics shows the file with its EXIF orientation applied: `rows[y][x]`.
private func orientedCells(_ data: Data, cell: Int) throws -> [[Int]] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 3 * cell,
    ]
    let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    let width = image.width, height = image.height
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return (0..<height / cell).map { cy in
        (0..<width / cell).map { cx in
            let offset = ((cy * cell + cell / 2) * width + cx * cell + cell / 2) * 4
            return nearestColor(Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }
    }
}

@Test func orientationMapsCorners() throws {
    // The pattern is stored 3 x 2 cells; for each tag, the cell CoreGraphics puts at oriented cell (x, y) must be the
    // stored cell `storedPoint` names (continuous coordinates, so the cell's centre).
    let stored = CGSize(width: 3, height: 2)
    for orientation in ImageOrientation.allCases {
        let data = TestJPEGs.pattern(cell: 8, orientation: orientation.rawValue)
        let cells = try orientedCells(data, cell: 8)
        let oriented = orientation.orientedSize(PixelSize(width: 3, height: 2))
        #expect(cells.count == oriented.height && cells[0].count == oriented.width, "\(orientation)")
        for y in 0..<oriented.height {
            for x in 0..<oriented.width {
                let point = orientation.storedPoint(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), storedSize: stored)
                let expected = TestJPEGs.patternColors.firstIndex {
                    let c = TestJPEGs.patternColor(x: Int(point.x), y: Int(point.y), cellsWide: 3)
                    return $0 == c
                }
                #expect(cells[y][x] == expected, "\(orientation) oriented (\(x), \(y)) -> stored \(point)")
            }
        }
    }
}

@Test func orientationCornersAreCorners() {
    // The stored image's corners land on the oriented image's corners (pixel edges at integers): 3 x 2 stored.
    let stored = CGSize(width: 3, height: 2)
    for orientation in ImageOrientation.allCases {
        let size = orientation.orientedSize(PixelSize(width: 3, height: 2))
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height),
                       CGPoint(x: size.width, y: size.height)].map { orientation.storedPoint($0, storedSize: stored) }
        #expect(Set(corners.map { "\($0.x),\($0.y)" })
                == ["0.0,0.0", "3.0,0.0", "0.0,2.0", "3.0,2.0"], "\(orientation): \(corners)")
    }
}

@Test func orientationKnownMappings() {
    // Stored top-left (0, 0) of a 3 x 2 picture, in each orientation's own picture: EXIF 6 turns the picture
    // clockwise, so it ends up top-right (2, 0) of the 2 x 3 result; 8 turns it the other way, bottom-left (0, 3).
    let stored = CGSize(width: 3, height: 2)
    #expect(ImageOrientation.right.orientedPoint(.zero, storedSize: stored) == CGPoint(x: 2, y: 0))
    #expect(ImageOrientation.left.orientedPoint(.zero, storedSize: stored) == CGPoint(x: 0, y: 3))
    #expect(ImageOrientation.upMirrored.orientedPoint(.zero, storedSize: stored) == CGPoint(x: 3, y: 0))
    #expect(ImageOrientation.down.orientedPoint(.zero, storedSize: stored) == CGPoint(x: 3, y: 2))
    #expect(ImageOrientation.leftMirrored.orientedPoint(CGPoint(x: 1, y: 0), storedSize: stored) == CGPoint(x: 0, y: 1))
}

@Test func roundTrip() {
    let stored = CGSize(width: 300, height: 200)
    for orientation in ImageOrientation.allCases {
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 12.25, y: 77.5), CGPoint(x: 199.75, y: 0.5)] {
            let back = orientation.orientedPoint(orientation.storedPoint(p, storedSize: stored), storedSize: stored)
            #expect(back == p, "\(orientation) \(p)")
            let there = orientation.storedPoint(orientation.orientedPoint(p, storedSize: stored), storedSize: stored)
            #expect(there == p, "\(orientation) \(p)")
        }
    }
}

@Test func matrixMapsAxes() {
    // Rows are stored x and stored y as combinations of oriented x and y: a rotation or mirror, never a shear.
    for orientation in ImageOrientation.allCases {
        let m = orientation.matrix
        #expect(abs(m.a * m.d - m.b * m.c) == 1, "\(orientation) determinant")
        #expect(abs(m.a) + abs(m.b) == 1 && abs(m.c) + abs(m.d) == 1, "\(orientation)")
        // The matrix swaps the axes exactly when the size does.
        #expect((m.a == 0) == orientation.swapsAxes, "\(orientation)")
        // With the translation `storedPoint` adds, it is the same map.
        let stored = CGSize(width: 30, height: 20)
        let p = CGPoint(x: 4, y: 9)
        let s = orientation.storedPoint(p, storedSize: stored)
        let tx = m.a + m.b < 0 ? stored.width : 0, ty = m.c + m.d < 0 ? stored.height : 0
        #expect(orientation.translation(storedSize: stored) == CGPoint(x: tx, y: ty), "\(orientation) translation")
        #expect(s == CGPoint(x: Double(m.a) * p.x + Double(m.b) * p.y + tx, y: Double(m.c) * p.x + Double(m.d) * p.y + ty))
    }
    #expect(ImageOrientation.up.matrix == (a: 1, b: 0, c: 0, d: 1))
}

@Test func storedRectMapsCorners() {
    // A 1 x 2 oriented rect at (0, 0) of a 3 x 2 stored picture: for EXIF 6 (turned clockwise to be shown) the oriented
    // top-left is the stored bottom-left, so the stored rect is 2 wide, 1 high, at (0, 1).
    let stored = CGSize(width: 3, height: 2)
    let rect = CGRect(x: 0, y: 0, width: 1, height: 2)
    #expect(ImageOrientation.up.storedRect(rect, storedSize: stored) == rect)
    #expect(ImageOrientation.right.storedRect(rect, storedSize: stored) == CGRect(x: 0, y: 1, width: 2, height: 1))
    #expect(ImageOrientation.down.storedRect(rect, storedSize: stored) == CGRect(x: 2, y: 0, width: 1, height: 2))
    for orientation in ImageOrientation.allCases {
        let r = CGRect(x: 0.25, y: 0.5, width: 1.5, height: 1.25), s = orientation.storedRect(r, storedSize: stored)
        let size = orientation.swapsAxes ? CGSize(width: r.height, height: r.width) : r.size
        #expect(s.size == size, "\(orientation)")
        // Its centre is the oriented centre's stored point.
        let centre = orientation.storedPoint(CGPoint(x: r.midX, y: r.midY), storedSize: stored)
        #expect(CGPoint(x: s.midX, y: s.midY) == centre, "\(orientation)")
    }
}

@Test func orientedSizeSwaps() {
    let stored = PixelSize(width: 3, height: 2)
    #expect(ImageOrientation.right.orientedSize(stored) == PixelSize(width: 2, height: 3))
    #expect(ImageOrientation.up.orientedSize(stored) == stored)
    #expect(ImageOrientation.downMirrored.orientedSize(stored) == stored)
    #expect(ImageOrientation.allCases.filter(\.swapsAxes).map(\.rawValue) == [5, 6, 7, 8])
}

@Test func rawValuesAreExifAndImageIOs() {
    #expect(ImageOrientation.allCases.map(\.rawValue) == Array(1...8))
    for orientation in ImageOrientation.allCases {
        #expect(CGImagePropertyOrientation(rawValue: UInt32(orientation.rawValue)) != nil)
    }
}

@Test func imageInfoOrientedSize() {
    let info = ImageInfo(pixelSize: PixelSize(width: 3, height: 2), typeIdentifier: "public.jpeg", isProgressive: false,
                         fileSize: 0, colorSpaceName: nil, orientation: .left)
    #expect(info.pixelSize == PixelSize(width: 3, height: 2) && info.orientedSize == PixelSize(width: 2, height: 3))
    #expect(info.displayOrientation(applying: true) == .left)
    #expect(info.displayOrientation(applying: false) == .up)
}

@Test func inverseUndoesTheOrientation() {
    // The inverse maps the stored layout back: stored by `o` and then by its inverse is the picture as first given.
    let stored = CGSize(width: 300, height: 200)
    for orientation in ImageOrientation.allCases {
        let oriented = orientation.orientedSize(PixelSize(width: 300, height: 200))
        let size = CGSize(width: oriented.width, height: oriented.height)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 12.25, y: 77.5), CGPoint(x: 199.75, y: 0.5)] {
            let there = orientation.storedPoint(p, storedSize: stored)
            #expect(orientation.inverse.storedPoint(there, storedSize: size) == p, "\(orientation) \(p)")
        }
        #expect(orientation.inverse.inverse == orientation)
    }
    #expect(ImageOrientation.right.inverse == .left && ImageOrientation.leftMirrored.inverse == .leftMirrored)
}

/// Review focus 1: the seeded thumbnail is already turned (`ThumbnailMaker` makes it oriented), so it is drawn with
/// `.up`, while the photo's decoded levels (stored as in the file) are drawn with its orientation.
@Test func seedIsNotRotatedTwice() {
    let info = ImageInfo(pixelSize: PixelSize(width: 4000, height: 3000), typeIdentifier: "public.jpeg",
                         isProgressive: false, fileSize: 0, colorSpaceName: nil, orientation: .right)
    #expect(info.drawOrientation(applying: true, seeded: true) == .up)
    #expect(info.drawOrientation(applying: true, seeded: false) == .right)
    // `exif-orientation=no` shows the stored layout: decoded levels as they are, the turned thumbnail turned back.
    #expect(info.drawOrientation(applying: false, seeded: false) == .up)
    #expect(info.drawOrientation(applying: false, seeded: true) == .left)
    // Either way, what is drawn has the size the view is laid out for.
    for applying in [true, false] {
        let seedGrid = info.orientedSize   // the seeded pyramid is the thumbnail's, in oriented layout
        #expect(info.drawOrientation(applying: applying, seeded: true).orientedSize(seedGrid) == info.displaySize(applying: applying))
        #expect(info.drawOrientation(applying: applying, seeded: false).orientedSize(info.pixelSize)
                == info.displaySize(applying: applying))
    }
    #expect(info.displaySize(applying: true) == PixelSize(width: 3000, height: 4000))
    #expect(info.displaySize(applying: false) == PixelSize(width: 4000, height: 3000))
}
