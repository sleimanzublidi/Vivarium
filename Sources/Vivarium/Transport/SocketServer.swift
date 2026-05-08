// Vivarium/Transport/SocketServer.swift
import Foundation
import Darwin

/// Listens on a Unix domain socket. Each client connection sends NDJSON lines.
/// Each line invokes the supplied handler asynchronously.
final class SocketServer {
    private let socketURL: URL
    private let onLine: @Sendable (Data) async -> Void

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let readQueue = DispatchQueue(label: "vivarium.socket.read", qos: .userInitiated, attributes: .concurrent)

    init(socketURL: URL, onLine: @escaping @Sendable (Data) async -> Void) throws {
        self.socketURL = socketURL
        self.onLine = onLine
    }

    func start() throws {
        // Refuse to start if another live instance is already listening at this path.
        // Without this, a second launch (Xcode test host, double-click while running, etc.)
        // would unlink the existing socket and silently steal the path — leaving the first
        // process bound to an FD with no filesystem name, so all clients hit a dead inode.
        if Self.isLiveListener(at: socketURL) {
            throw NSError(domain: "SocketServer", code: Int(EADDRINUSE),
                          userInfo: [NSLocalizedDescriptionKey:
                                     "another process is already listening at \(socketURL.path)"])
        }
        // Clean up any stale socket file.
        try? FileManager.default.removeItem(at: socketURL)
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let written = path.withCString { src -> Bool in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                let cap = dst.count - 1
                let n = strlen(src)
                if n >= cap { return false }
                memcpy(dst.baseAddress!, src, n + 1)
                return true
            }
        }
        guard written else { close(fd); throw posixError("path-too-long") }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult: Int32 = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindResult == 0 else { close(fd); throw posixError("bind") }

        // Permissions are set immediately, before any peer can connect.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else { close(fd); throw posixError("listen") }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "vivarium.accept"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop() {
        while true {
            let server = listenFD
            if server < 0 { return }
            var addr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(server, $0, &addrLen)
                }
            }
            if cfd < 0 { return }   // listening socket closed
            readQueue.async { [weak self] in self?.readLoop(fd: cfd) }
        }
    }

    private func readLoop(fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                if !line.isEmpty {
                    Task { await self.onLine(line) }
                }
            }
        }
    }

    private func posixError(_ op: String) -> NSError {
        NSError(domain: "SocketServer", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: errno=\(errno)"])
    }

    /// Is there an accepting AF_UNIX listener on `url` right now?
    ///
    /// Only `connect()` distinguishes a live listener from a stale/orphaned socket file:
    ///   - regular file or dangling named socket → ECONNREFUSED / ENOTSOCK / ENOENT → false
    ///   - active listener                       → connect succeeds                → true
    /// (`bind()` can't be used as a probe because the prior code path always unlinks first.)
    private static func isLiveListener(at url: URL) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        let written = path.withCString { src -> Bool in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                let cap = dst.count - 1
                let n = strlen(src)
                if n >= cap { return false }
                memcpy(dst.baseAddress!, src, n + 1)
                return true
            }
        }
        guard written else { return false }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result: Int32 = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) }
        }
        return result == 0
    }
}
