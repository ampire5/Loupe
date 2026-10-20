import Darwin
import Foundation

enum ReadTimer {
    struct Failure: Error, CustomStringConvertible {
        let path: String
        let errnoValue: Int32
        var description: String { "\(path): \(String(cString: strerror(errnoValue)))" }
    }

    /// Reads a whole file with the page cache bypassed (`F_NOCACHE`), so repeated runs measure the
    /// network/disk and not RAM. Returns the bytes and the wall-clock time in milliseconds.
    static func read(_ url: URL) throws -> (data: Data, ms: Double) {
        let path = url.path
        let start = DispatchTime.now().uptimeNanoseconds
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw Failure(path: path, errnoValue: errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure(path: path, errnoValue: errno) }
        var data = Data(count: Int(st.st_size))
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress! + offset, buf.count - offset)
            }
            if n < 0 { throw Failure(path: path, errnoValue: errno) }
            if n == 0 { data.removeSubrange(offset...); break }  // file shrank underneath us
            offset += n
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        return (data, ms)
    }
}
