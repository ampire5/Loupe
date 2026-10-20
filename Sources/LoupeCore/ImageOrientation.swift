import CoreGraphics

/// The EXIF orientation of a picture (tag 1...8, the raw values of `CGImagePropertyOrientation`): how the stored
/// pixels are turned and mirrored to get the picture the photographer saw. Pixels are never rotated here; the
/// renderer maps oriented coordinates to stored ones, and everything the user sees (zoom, fit, centre, saved view)
/// works in the oriented size (spec M3b §2.1). All points are continuous, pixel edges at integers.
public enum ImageOrientation: Int, Sendable, CaseIterable {
    /// Stored as shown.
    case up = 1
    /// Mirrored left to right.
    case upMirrored
    /// Turned 180 degrees.
    case down
    /// Mirrored top to bottom.
    case downMirrored
    /// Transposed: stored rows are the oriented columns.
    case leftMirrored
    /// Turned 90 degrees clockwise to be shown.
    case right
    /// Anti-transposed: transposed and turned 180 degrees.
    case rightMirrored
    /// Turned 90 degrees counter-clockwise to be shown.
    case left

    /// Width and height trade places (5...8).
    public var swapsAxes: Bool { rawValue >= ImageOrientation.leftMirrored.rawValue }

    /// The orientation that turns the oriented picture back into the stored one: the opposite quarter turn for 6 and
    /// 8, the orientation itself for the others (a half turn, a mirror or a transpose undoes itself).
    public var inverse: ImageOrientation {
        switch self {
        case .right: return .left
        case .left: return .right
        default: return self
        }
    }

    /// The size of the picture as shown, from the stored one.
    public func orientedSize(_ stored: PixelSize) -> PixelSize {
        swapsAxes ? PixelSize(width: stored.height, height: stored.width) : stored
    }

    /// The map from oriented to stored axes as a 2x2 matrix of 0 and plus or minus 1: stored x = `a` * x + `b` * y,
    /// stored y = `c` * x + `d` * y, plus the shift that brings a mirrored axis back into the picture
    /// (`translation`). One non-zero entry per row and column: a rotation or a mirror.
    public var matrix: (a: Int, b: Int, c: Int, d: Int) {
        switch self {
        case .up: return (1, 0, 0, 1)
        case .upMirrored: return (-1, 0, 0, 1)
        case .down: return (-1, 0, 0, -1)
        case .downMirrored: return (1, 0, 0, -1)
        case .leftMirrored: return (0, 1, 1, 0)
        case .right: return (0, 1, -1, 0)
        case .rightMirrored: return (0, -1, -1, 0)
        case .left: return (0, -1, 1, 0)
        }
    }

    /// The shift that follows `matrix`: the stored width (height) on a stored axis the matrix mirrors (its row sums to
    /// -1), 0 on the others, so the picture lands back in 0...size. The renderer passes it with the matrix, in level
    /// px (`storedSize` the level's extent).
    public func translation(storedSize: CGSize) -> CGPoint {
        let m = matrix
        return CGPoint(x: m.a + m.b < 0 ? storedSize.width : 0, y: m.c + m.d < 0 ? storedSize.height : 0)
    }

    /// The point of the stored picture (`storedSize` wide and high) that shows at `oriented` in the shown one.
    public func storedPoint(_ oriented: CGPoint, storedSize: CGSize) -> CGPoint {
        let m = matrix, shift = translation(storedSize: storedSize)
        return CGPoint(x: Double(m.a) * oriented.x + Double(m.b) * oriented.y + shift.x,
                       y: Double(m.c) * oriented.x + Double(m.d) * oriented.y + shift.y)
    }

    /// Where the stored point `stored` shows in the oriented picture; the inverse of `storedPoint`.
    public func orientedPoint(_ stored: CGPoint, storedSize: CGSize) -> CGPoint {
        let m = matrix, shift = translation(storedSize: storedSize)
        let x = stored.x - shift.x, y = stored.y - shift.y
        // The matrix is orthogonal, so its inverse is its transpose.
        return CGPoint(x: Double(m.a) * x + Double(m.c) * y, y: Double(m.b) * x + Double(m.d) * y)
    }

    /// The stored rect that shows as `oriented` (both continuous): the box of its mapped corners, a turned or mirrored
    /// rect being a rect.
    public func storedRect(_ oriented: CGRect, storedSize: CGSize) -> CGRect {
        let a = storedPoint(CGPoint(x: oriented.minX, y: oriented.minY), storedSize: storedSize)
        let b = storedPoint(CGPoint(x: oriented.maxX, y: oriented.maxY), storedSize: storedSize)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
