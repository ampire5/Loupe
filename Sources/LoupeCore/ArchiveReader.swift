import Compression
import Foundation
import zlib

/// Reads zip archives on a share without copying them (Stash spec §2.4): the central directory once per archive (the
/// file's tail, one more read when the directory starts before it), then each entry as one ranged read of its local
/// header and one of its data, inflated in memory. Directories are cached by path while the archive's stamp stays
/// the same (64 archives, least recently used dropped). Blocking: `FileReader` runs it on its pool, others off the
/// main thread.
public final class ArchiveReader: @unchecked Sendable {
    public typealias PRead = @Sendable (Int32, UnsafeMutableRawPointer, Int, Int) -> Int

    public static let shared = ArchiveReader()

    private let pread: PRead
    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, directory: ZipDirectory, used: UInt64)] = [:]
    private var clock: UInt64 = 0
    private static let cacheLimit = 64

    public init(pread: @escaping PRead = FileReader.pread) {
        self.pread = pread
    }

    public func directory(of archive: URL) throws -> ZipDirectory {
        try withOpen(archive) { fd, stamp in try directory(fd: fd, stamp: stamp, path: archive.path, io: IO(pread)) }
    }

    /// The archive's photos as entry URLs with their stamps, in directory order: entries whose last name has an image
    /// extension; not directories, `__MACOSX/…`, `._*` names, or names with "∕" (`ArchivePath.url` refuses them).
    public func entries(of archive: URL) throws -> [(url: URL, stamp: FileStamp)] {
        try listing(of: archive).entries
    }

    /// `entries`, with the archive's own stamp (its size and date) from the same open: a zip card's summary.
    public func listing(of archive: URL) throws -> (stamp: FileStamp, entries: [(url: URL, stamp: FileStamp)]) {
        try withOpen(archive) { fd, stamp in
            let entries = try directory(fd: fd, stamp: stamp, path: archive.path, io: IO(pread)).entries.compactMap {
                entry -> (url: URL, stamp: FileStamp)? in
                let last = entry.name.split(separator: "/").last.map(String.init) ?? ""
                guard !entry.isDirectory, !entry.name.hasPrefix("__MACOSX/"), !last.hasPrefix("._"),
                      Playlist.imageExtensions.contains((last as NSString).pathExtension.lowercased()),
                      let url = ArchivePath.url(archive: archive, entry: entry.name) else { return nil }
                return (url, FileStamp(modified: stamp.modified, size: entry.size))
            }
            return (stamp, entries)
        }
    }

    public func read(_ entry: URL) throws -> FileBytes { try read(entry, io: IO(pread)) }

    public func stamp(_ entry: URL) throws -> FileStamp {
        guard let (archive, name) = ArchivePath.split(entry) else { throw ArchiveError.entryNotFound }
        return try withOpen(archive) { fd, stamp in
            let e = try find(name, in: directory(fd: fd, stamp: stamp, path: archive.path, io: IO(pread)))
            return FileStamp(modified: stamp.modified, size: e.size)
        }
    }

    /// `FileReader`'s path: its `pread` and its job's progress and cancellation.
    func read(_ entry: URL, io: IO) throws -> FileBytes {
        guard let (archive, name) = ArchivePath.split(entry) else { throw ArchiveError.entryNotFound }
        return try withOpen(archive) { fd, stamp in
            let e = try find(name, in: directory(fd: fd, stamp: stamp, path: archive.path, io: io))
            if e.isEncrypted { throw ArchiveError.encrypted }
            guard e.method == 0 || e.method == 8 else { throw ArchiveError.unsupportedMethod(e.method) }
            try ZipDirectory.checkSizes(e)
            let header = try io.read(fd, at: e.localHeaderOffset, count: ZipDirectory.localHeaderLength)
            let start = try ZipDirectory.dataOffset(localHeader: header, entry: e)
            let (end, overflow) = start.addingReportingOverflow(e.compressedSize)
            guard !overflow, end <= stamp.size else { throw ArchiveError.damaged }
            let packed = try io.read(fd, at: start, count: e.compressedSize)
            let data = e.method == 0 ? packed : try Self.inflate(packed, size: e.size)
            guard data.count == e.size, Self.crc(data) == e.crc32 else { throw ArchiveError.damaged }
            return FileBytes(data: data, stamp: FileStamp(modified: stamp.modified, size: e.size))
        }
    }

    // MARK: Inside

    /// Ranged reads in 1 MiB steps, with a progress / cancellation hook between them.
    struct IO {
        let pread: PRead
        var step: () throws -> Void = {}

        init(_ pread: @escaping PRead, step: @escaping () throws -> Void = {}) {
            self.pread = pread
            self.step = step
        }

        func read(_ fd: Int32, at offset: Int, count: Int) throws -> Data {
            guard count > 0 else { return Data() }
            var data = Data(count: count)
            var filled = 0
            try data.withUnsafeMutableBytes { buffer in
                let base = buffer.baseAddress!
                while filled < count {
                    try step()
                    let n = pread(fd, base + filled, min(1 << 20, count - filled), offset + filled)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if n == 0 { throw ArchiveError.damaged }   // shorter than the directory says
                    filled += n
                }
            }
            try step()
            return data
        }
    }

    private func withOpen<T>(_ archive: URL, _ body: (Int32, FileStamp) throws -> T) throws -> T {
        let fd = open(archive.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body(fd, FileStamp(st))
    }

    private func directory(fd: Int32, stamp: FileStamp, path: String, io: IO) throws -> ZipDirectory {
        if let hit = lock.withLock({ () -> ZipDirectory? in
            guard let c = cache[path], c.stamp == stamp else { return nil }
            clock += 1
            cache[path]!.used = clock
            return c.directory
        }) { return hit }
        let tailCount = min(stamp.size, ZipDirectory.tailLength)
        let tailStart = stamp.size - tailCount
        let tail = try io.read(fd, at: tailStart, count: tailCount)
        let place = try ZipDirectory.locate(tail: tail, fileSize: stamp.size)
        let bytes = place.offset >= tailStart
            ? tail.subdata(in: (place.offset - tailStart)..<(place.offset - tailStart + place.size))
            : try io.read(fd, at: place.offset, count: place.size)
        let directory = try ZipDirectory.parse(bytes)
        lock.withLock {
            clock += 1
            cache[path] = (stamp, directory, clock)
            if cache.count > Self.cacheLimit, let old = cache.min(by: { $0.value.used < $1.value.used })?.key {
                cache[old] = nil
            }
        }
        return directory
    }

    private func find(_ name: String, in directory: ZipDirectory) throws -> ZipEntry {
        guard let e = directory.entries.first(where: { $0.name == name }) else { throw ArchiveError.entryNotFound }
        return e
    }

    private static func inflate(_ packed: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            packed.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil,
                                          COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw ArchiveError.damaged }
        return out
    }

    private static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
}
