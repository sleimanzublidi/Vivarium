// LittleGuyTests/Transport/SocketServerTests.swift
import XCTest
import Darwin
@testable import LittleGuy

final class SocketServerTests: XCTestCase {
    private func tempSocketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lg-\(UUID().uuidString).sock")
    }

    func test_acceptsAndReceivesNDJSONLine() async throws {
        let url = tempSocketURL()
        let received = AsyncChannel<Data>()
        let server = try SocketServer(socketURL: url) { line in
            await received.send(line)
        }
        try server.start()
        defer { server.stop() }

        // Connect a UNIX socket client and send one line.
        let line = #"{"agent":"claude-code","event":"X","payload":{}}"#
        try writeLineToSocket(at: url, line: line + "\n")

        let firstTask = Task { await received.first() }
        let got = try await withTimeout(seconds: 2) { await firstTask.value }
        XCTAssertEqual(String(data: got, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), line)
    }

    func test_unlinksStaleSocketFile() throws {
        let url = tempSocketURL()
        FileManager.default.createFile(atPath: url.path, contents: Data("stale".utf8))
        let server = try SocketServer(socketURL: url) { _ in }
        XCTAssertNoThrow(try server.start())
        server.stop()
    }

    func test_socketFileMode_is0600() throws {
        let url = tempSocketURL()
        let server = try SocketServer(socketURL: url) { _ in }
        try server.start()
        defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600)
    }
}

// MARK: - tiny test helpers

actor AsyncChannel<T: Sendable>: Sendable {
    private var buf: [T] = []
    private var waiters: [CheckedContinuation<T, Never>] = []
    func send(_ v: T) {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: v) }
        else { buf.append(v) }
    }
    func first() async -> T {
        if !buf.isEmpty { return buf.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(domain: "timeout", code: 0)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

func writeLineToSocket(at url: URL, line: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertTrue(fd >= 0)
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = url.path
    _ = path.withCString { src in
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            strncpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count - 1)
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r: Int32 = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, len)
        }
    }
    XCTAssertEqual(r, 0, "connect failed: errno=\(errno)")
    let data = Array(line.utf8)
    let n = write(fd, data, data.count)
    XCTAssertEqual(n, data.count)
}
