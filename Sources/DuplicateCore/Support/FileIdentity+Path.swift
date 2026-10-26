import Foundation

extension FileIdentity {
    /// The identity of what `path` names, without following a final symlink, or `nil` when it cannot be read.
    public init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.init(volume: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Whether two paths name one file.
    ///
    /// For the case a rename makes (#228): on a volume that ignores case, `IMG.JPG` and `img.JPG` are one file, and
    /// asking whether one "exists" while the other is the file says yes. A path that cannot be read is no file's twin.
    @Sendable public static func same(_ first: String, _ second: String) -> Bool {
        guard let one = FileIdentity(path: first), let other = FileIdentity(path: second) else {
            return false
        }
        return one == other
    }
}
