import Darwin
import Foundation

/// The local socket between the helper and Orbit. A Unix domain socket in a
/// folder only the current user can open; never a network port.
package enum UnixSocket {
    /// ~/Library/Application Support/Orbit/Bridge/brave.sock
    package static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Orbit/Bridge/brave.sock").path(percentEncoded: false)
    }

    package struct Failure: Error, CustomStringConvertible {
        package let description: String
        init(_ what: String, _ code: Int32 = errno) { description = "\(what): \(String(cString: strerror(code)))" }
    }

    /// Listens at `path`. The folder is created (or tightened) to 0700 and the
    /// socket to 0600. A stale socket is replaced; a live one (another Orbit)
    /// or anything that isn't a socket is left alone.
    package static func listen(at path: String) throws(Failure) -> Int32 {
        let folder = (path as NSString).deletingLastPathComponent
        var info = stat()
        if lstat(folder, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw Failure("socket folder isn't ours", EPERM) }
            chmod(folder, 0o700)
        } else {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw Failure("create socket folder", EACCES)
            }
        }
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw Failure("socket path is taken", EEXIST) }
            if let live = try? connect(to: path) {
                close(live)
                throw Failure("another Orbit is listening", EADDRINUSE)
            }
            unlink(path)
        }
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            let failure = Failure("bind")
            close(fd)
            throw failure
        }
        configure(fd)
        return fd
    }

    /// Connects to `path`, and only to a socket owned by the current user.
    package static func connect(to path: String) throws(Failure) -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let failure = Failure("connect")
            close(fd)
            throw failure
        }
        guard peerIsCurrentUser(fd) else {
            close(fd)
            throw Failure("socket owned by another user", EPERM)
        }
        configure(fd)
        return fd
    }

    package static func accept(_ listener: Int32) -> Int32? {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        guard peerIsCurrentUser(fd) else {
            close(fd)
            return nil
        }
        configure(fd)
        return fd
    }

    package static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid = uid_t(), gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Writes everything or fails. Sockets have a 1 s send timeout, so a
    /// stuck peer can't hang the caller.
    package static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// One read of up to 64 KiB: nil at end of stream or on error.
    package static func readChunk(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            return count > 0 ? Data(buffer[..<count]) : nil
        }
    }

    private static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    private static func address(_ path: String) throws(Failure) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { throw Failure("socket path too long", ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
