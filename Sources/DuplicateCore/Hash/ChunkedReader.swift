import Foundation

/// Reads a file in fixed chunks through one reusable, page-aligned buffer.
///
/// Not `FileHandle.read(upToCount:)`, and the reason is arithmetic. That call allocates a fresh
/// `Data` per chunk, so hashing 500 GB in 1 MiB pieces means half a million heap allocations and half
/// a million copies. One buffer, reused for the reader's lifetime, and `SHA256.update(bufferPointer:)`
/// consuming it in place, removes both.
///
/// The buffer is page-aligned because `F_NOCACHE` reads into an unaligned user buffer force the
/// kernel to bounce-buffer, which gives back the copy this type exists to avoid.
///
/// Not `Data(contentsOf:)` either: a 4 GB video read whole, times eight concurrent hashers, is a
/// 32 GB spike.
final class ChunkedReader {
    private var descriptor: Int32
    private let buffer: UnsafeMutableRawBufferPointer
    private let path: String

    /// Chunk size, and therefore the buffer size.
    let capacity: Int

    /// Opens `path` for reading.
    ///
    /// - Parameter bypassingCache: when true, sets `F_NOCACHE` so the read does not populate the
    ///   unified buffer cache. A multi-hundred-gigabyte scan with caching on evicts the user's entire
    ///   working set, and the user experiences that as "my Mac got slow and stayed slow". There is no
    ///   second read of a large file to benefit from the cache; the hash cache, not the page cache, is
    ///   what makes a rescan fast.
    init(path: String, capacity: Int, bypassingCache: Bool) throws {
        precondition(capacity > 0, "capacity must be positive")
        let descriptor = path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw HashingError.cannotOpen(path: path, code: errno)
        }
        if bypassingCache {
            // Advisory. A failure here costs page-cache pressure, not correctness, so it is not
            // worth failing the read over.
            _ = fcntl(descriptor, F_NOCACHE, 1)
        }

        var raw: UnsafeMutableRawPointer?
        let alignment = Int(getpagesize())
        guard posix_memalign(&raw, alignment, capacity) == 0, let allocated = raw else {
            close(descriptor)
            throw HashingError.outOfMemory(bytes: capacity)
        }

        self.descriptor = descriptor
        self.path = path
        self.capacity = capacity
        buffer = UnsafeMutableRawBufferPointer(start: allocated, count: capacity)
    }

    deinit {
        buffer.baseAddress?.deallocate()
        if descriptor >= 0 { close(descriptor) }
    }

    /// Reads up to `capacity` bytes at `offset` and returns a view of the shared buffer.
    ///
    /// The returned pointer is only valid until the next call. An empty result means end of file.
    ///
    /// `pread` rather than `read` so the file offset is never implicit: the prefix stage reads the
    /// head and then the tail, and a shared offset would make those two calls order-dependent.
    func read(at offset: Int64, upTo count: Int? = nil) throws -> UnsafeRawBufferPointer {
        let wanted = min(count ?? capacity, capacity)
        guard wanted > 0 else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        var read = 0
        while read < wanted {
            let result = pread(
                descriptor,
                buffer.baseAddress!.advanced(by: read),
                wanted - read,
                off_t(offset) + off_t(read)
            )
            if result < 0 {
                // A signal can interrupt a read on a slow volume; that is not a failure.
                if errno == EINTR { continue }
                throw HashingError.readFailed(path: path, code: errno)
            }
            if result == 0 { break }  // End of file.
            read += result
        }
        return UnsafeRawBufferPointer(start: buffer.baseAddress, count: read)
    }

    /// The size the filesystem reports right now, which can differ from what the walk recorded.
    func currentSize() throws -> Int64 {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw HashingError.readFailed(path: path, code: errno)
        }
        return Int64(info.st_size)
    }
}

/// Why a file could not be hashed.
///
/// Carries the raw `errno` rather than a message: the presentation layer turns it into a localised
/// sentence, so `DuplicateCore` stays language-free. `EACCES` and `ENOENT` mean very different things
/// to a user staring at a scan that found nothing.
public enum HashingError: Error, Equatable, Sendable {
    case cannotOpen(path: String, code: Int32)
    case readFailed(path: String, code: Int32)
    case outOfMemory(bytes: Int)

    /// Whether this is the ordinary "the file went away or is not readable" case, which a scan should
    /// skip rather than abort on. The CLI's `sha256_file` returns `None` for exactly these
    /// (`src/rav/core/duplicates.py:208-219`).
    public var isSkippable: Bool {
        switch self {
        case .cannotOpen(_, let code), .readFailed(_, let code):
            code == ENOENT || code == EACCES || code == EPERM || code == EISDIR
        case .outOfMemory:
            false
        }
    }
}
