// VivariumNotify/main.swift
import Foundation
import Darwin

// Usage: VivariumNotify --agent claude-code  (reads stdin JSON)
//        VivariumNotify --agent copilot-cli
//
// Reads stdin, wraps it in an envelope, writes one NDJSON line to ~/.vivarium/sock
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

// Copilot CLI's hook stdin doesn't include `cwd`. The hook runs as a child
// of the Copilot CLI process so our own working directory == Copilot's,
// which is the project the user is invoking the agent in. Inject it into
// the payload (without overriding anything the agent may already provide,
// like Claude Code's `cwd`) so the downstream adapter can resolve a project.
let payloadAny: Any
if var dict = stdinJSON as? [String: Any] {
    if dict["cwd"] == nil {
        dict["cwd"] = FileManager.default.currentDirectoryPath
    }
    payloadAny = dict
} else {
    payloadAny = stdinJSON
}

let envelope: [String: Any] = [
    "agent": agent,
    "event": resolvedEvent,
    "payload": payloadAny,
    "pid": getpid(),
    "ppid": getppid(),
    "ancestors": processAncestors(startingAt: getpid()),
    "receivedAt": Date().timeIntervalSince1970,
]
guard let line = try? JSONSerialization.data(withJSONObject: envelope) else { exit(0) }

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let path = "\(home)/.vivarium/sock"

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
    _ = withUnsafeMutableBytes(of: &writeSet) { ptr in
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

private func processAncestors(startingAt pid: pid_t, maxDepth: Int = 12) -> [[String: Any]] {
    var result: [[String: Any]] = []
    var seen = Set<pid_t>()
    var current = pid

    for _ in 0..<maxDepth {
        guard current > 1, seen.insert(current).inserted,
              let snapshot = processSnapshot(pid: current)
        else { break }

        result.append(snapshot)
        guard let parent = snapshot["ppid"] as? Int, parent > 1 else { break }
        current = pid_t(parent)
    }

    return result
}

private func processSnapshot(pid: pid_t) -> [String: Any]? {
    guard let info = processKernelInfo(pid: pid) else { return nil }
    let parentPID = Int(info.kp_eproc.e_ppid)

    var snapshot: [String: Any] = [
        "pid": Int(pid),
        "ppid": parentPID,
        "command": processCommandName(from: info),
        "args": processArguments(pid: pid),
    ]

    if let path = processExecutablePath(pid: pid), !path.isEmpty {
        snapshot["path"] = path
    }

    let startedAt = TimeInterval(info.kp_proc.p_starttime.tv_sec)
        + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
    if startedAt > 0 {
        snapshot["startedAt"] = startedAt
    }

    return snapshot
}

private func processKernelInfo(pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
          size >= MemoryLayout<kinfo_proc>.stride,
          info.kp_proc.p_pid == pid
    else {
        return nil
    }
    return info
}

private func processCommandName(from info: kinfo_proc) -> String {
    var command = info.kp_proc.p_comm
    let capacity = MemoryLayout.size(ofValue: command)
    return withUnsafePointer(to: &command) { pointer in
        pointer.withMemoryRebound(to: CChar.self,
                                  capacity: capacity) { cString in
            String(cString: cString)
        }
    }
}

private func processExecutablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

private func processArguments(pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size: size_t = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
          size > MemoryLayout<Int32>.size
    else {
        return []
    }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
        return []
    }

    var argc: Int32 = 0
    withUnsafeMutableBytes(of: &argc) { argcBytes in
        buffer.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.baseAddress,
                  let destination = argcBytes.baseAddress
            else { return }
            memcpy(destination, source, MemoryLayout<Int32>.size)
        }
    }

    let stringLimit = max(0, Int(argc) + 1)
    var result: [String] = []
    var current: [UInt8] = []

    for byte in buffer.dropFirst(MemoryLayout<Int32>.size) {
        if byte == 0 {
            if !current.isEmpty {
                result.append(String(decoding: current, as: UTF8.self))
                current.removeAll()
                if result.count >= stringLimit { break }
            }
        } else {
            current.append(byte)
        }
    }

    if !current.isEmpty, result.count < stringLimit {
        result.append(String(decoding: current, as: UTF8.self))
    }

    return result
}
