// LittleGuyNotify/main.swift
import Foundation
import Darwin

// Usage: LittleGuyNotify --agent claude-code  (reads stdin JSON)
//        LittleGuyNotify --agent copilot-cli
//
// Reads stdin, wraps it in an envelope, writes one NDJSON line to ~/.littleguy/sock
// with hard 200ms timeouts on both connect and write. Drops on failure. Always
// exits 0 so a missing or busy app never breaks the calling agent.

let args = CommandLine.arguments
var agent = "unknown"
var event: String? = nil
var i = 1
while i < args.count {
    switch args[i] {
    case "--agent":
        if i + 1 < args.count { agent = args[i + 1]; i += 1 }
    case "--event":
        if i + 1 < args.count { event = args[i + 1]; i += 1 }
    default: break
    }
    i += 1
}

let stdin = FileHandle.standardInput.readDataToEndOfFile()
guard let stdinJSON = try? JSONSerialization.jsonObject(with: stdin) else {
    exit(0)
}

let resolvedEvent: Any
if let explicit = event {
    resolvedEvent = explicit
} else if let dict = stdinJSON as? [String: Any], let hookName = dict["hook_event_name"] {
    resolvedEvent = hookName
} else {
    resolvedEvent = ""
}

let envelope: [String: Any] = [
    "agent": agent,
    "event": resolvedEvent,
    "payload": stdinJSON,
    "pid": getpid(),
    "ppid": getppid(),
    "receivedAt": Date().timeIntervalSince1970,
]
guard let line = try? JSONSerialization.data(withJSONObject: envelope) else { exit(0) }

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let path = "\(home)/.littleguy/sock"

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
if fd < 0 { exit(0) }
defer { close(fd) }

// Send timeout = 200 ms (covers post-connect write).
var sendTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
_ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let written = path.withCString { src -> Bool in
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        let cap = dst.count - 1
        let n = strlen(src)
        if n >= cap { return false }
        memcpy(dst.baseAddress!, src, n + 1)
        return true
    }
}
if !written { exit(0) }

// --- Connect with a 200 ms timeout (P0 fix #1) ---
// SO_SNDTIMEO does NOT bound connect() on AF_UNIX on Darwin; we need
// non-blocking + select() to enforce the deadline.
let originalFlags = fcntl(fd, F_GETFL)
if originalFlags < 0 { exit(0) }
_ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

let len = socklen_t(MemoryLayout<sockaddr_un>.size)
let connectResult: Int32 = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
}
if connectResult != 0 {
    if errno != EINPROGRESS { exit(0) }
    var writeSet = fd_set()
    // FD_ZERO / FD_SET are macros not visible in Swift; implement manually.
    withUnsafeMutableBytes(of: &writeSet) { ptr in
        ptr.initializeMemory(as: UInt8.self, repeating: 0)
    }
    let words = MemoryLayout<fd_set>.size / 4
    withUnsafeMutablePointer(to: &writeSet) { p in
        p.withMemoryRebound(to: Int32.self, capacity: words) { arr in
            arr[Int(fd) >> 5] |= Int32(1) << (fd & 31)
        }
    }
    var connectTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
    let ready = select(fd + 1, nil, &writeSet, nil, &connectTimeout)
    if ready <= 0 { exit(0) }
    var soError: Int32 = 0
    var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
    _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen)
    if soError != 0 { exit(0) }
}

// Restore blocking mode for the write phase (SO_SNDTIMEO will bound it).
_ = fcntl(fd, F_SETFL, originalFlags)

// --- Write with partial-write loop (P0 fix #2) ---
var payload = line
payload.append(0x0A)   // newline terminator
var remaining = payload
while !remaining.isEmpty {
    let n = remaining.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
        write(fd, bytes.baseAddress, bytes.count)
    }
    if n < 0 {
        if errno == EINTR { continue }   // signal — retry
        break                            // any other error — drop
    }
    if n == 0 { break }                  // nothing more we can do
    remaining = remaining.dropFirst(n)
}

exit(0)
