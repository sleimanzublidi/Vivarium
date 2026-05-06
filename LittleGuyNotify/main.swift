// LittleGuyNotify/main.swift
import Foundation
import Darwin

// Usage: LittleGuyNotify --agent claude-code  (reads stdin JSON)
//        LittleGuyNotify --agent copilot-cli
//
// Reads stdin, wraps it in an envelope, writes one NDJSON line to ~/.littleguy/sock
// with hard 200ms timeouts. Drops on failure. Always exits 0.

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
    exit(0)   // not JSON; drop silently per spec
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

// Set send timeout = 200 ms.
var tv = timeval(tv_sec: 0, tv_usec: 200_000)
_ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

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

let len = socklen_t(MemoryLayout<sockaddr_un>.size)
let connectResult: Int32 = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, len)
    }
}
if connectResult != 0 { exit(0) }

var payload = line
payload.append(0x0A)   // newline
_ = payload.withUnsafeBytes { bytes in
    write(fd, bytes.baseAddress, bytes.count)
}

exit(0)
