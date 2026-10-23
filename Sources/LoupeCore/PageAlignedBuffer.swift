import Darwin

public enum DecodeError: Error, Equatable {
    case unreadable
    case outOfMemory
    /// The image needs more tiles in one pyramid level than a Metal texture array can hold
    /// (`TileGrid.maxTilesPerLevel`); detected from the header, before any pixel is decoded.
    case tooLarge
}

/// Memory aligned to, and sized in whole multiples of, the 16 KiB VM page. Metal's
/// `makeBuffer(bytesNoCopy:)` demands both, and wrapping the decoder's output that way lets the
/// GPU read the pixels without a copy of a 500+ MB image.
///
/// Mapped straight from the kernel (`mmap`) and unmapped on release, so a freed frame leaves the process at
/// once: through malloc, freed 0.5 GB blocks stayed resident and counted in `phys_footprint` (M2 spec §11.3).
public final class PageAlignedBuffer: @unchecked Sendable {
    /// Apple Silicon VM page size; also what `makeBuffer(bytesNoCopy:)` requires on this hardware. On Intel (4 KiB
    /// pages) a multiple of the page, so the same alignment and sizes serve both.
    public static let pageSize = 16 * 1024

    public let bytes: UnsafeMutableRawPointer
    /// `minimumLength` rounded up to a whole number of pages.
    public let length: Int

    /// The contents read as zero: the kernel supplies zero-filled pages on first touch, so nothing is cleared
    /// up front on the critical path of opening a photo. Throws `DecodeError.outOfMemory` if the size is
    /// negative, the rounding overflows, or the mapping fails.
    public init(minimumLength: Int) throws {
        let page = Self.pageSize
        guard minimumLength >= 0 else { throw DecodeError.outOfMemory }
        let (rounded, overflow) = minimumLength.addingReportingOverflow(page - 1)
        guard !overflow else { throw DecodeError.outOfMemory }
        let length = max(page, rounded / page * page)
        // mmap aligns to the VM page, 16 KiB on Apple Silicon but 4 KiB on Intel and under Rosetta:
        // one page more is mapped and the parts before the first 16 KiB boundary and after `length` given back.
        let (mapped, tooLarge) = length.addingReportingOverflow(page)
        guard !tooLarge, let pointer = mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              pointer != mapFailed else { throw DecodeError.outOfMemory }
        let head = (page - Int(bitPattern: pointer) % page) % page
        if head > 0 { munmap(pointer, head) }
        munmap(pointer + head + length, page - head)
        self.bytes = pointer + head
        self.length = length
    }

    deinit { munmap(bytes, length) }
}

/// `MAP_FAILED` (a C cast Swift does not import).
private let mapFailed = UnsafeMutableRawPointer(bitPattern: -1)!
