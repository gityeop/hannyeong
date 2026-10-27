import Foundation
import Darwin

/// Kernel process/TTY metadata only. Never reads arguments, terminal output or input bytes.
enum SudoPasswordProbe {
    struct Entry: Sendable {
        let pid: pid_t
        let parent: pid_t
        let group: pid_t
        let tty: dev_t
        let foregroundGroup: pid_t
        let name: String
    }
    struct TTYState {
        let echo: Bool
    }

    static func active(rootPID: pid_t) throws -> Bool {
        try active(rootPID: rootPID, entries: snapshot(), ttyState: ttyState)
    }

    static func active(rootPID: pid_t, entries: [Entry], ttyState: (dev_t) throws -> TTYState?) throws -> Bool {
        let byPID = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) })
        let children = Dictionary(grouping: entries, by: \.parent)
        for entry in entries where entry.name == "sudo" && entry.tty != -1 && entry.group > 0 && entry.foregroundGroup == entry.group {
            var parent = entry.parent
            while parent > 1 && parent != rootPID { parent = byPID[parent]?.parent ?? 0 }
            guard parent == rootPID else { continue }
            // A sudo monitor may keep the outer TTY while a command/editor runs in a nested PTY.
            var descendants = children[entry.pid] ?? []
            var commandStarted = false
            while let child = descendants.popLast() {
                if child.name != "sudo" { commandStarted = true; break }
                descendants += children[child.pid] ?? []
            }
            guard !commandStarted, let tty = try ttyState(entry.tty) else { continue }
            if !tty.echo { return true }
        }
        return false
    }

    static func snapshot() throws -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var bytes = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &bytes, nil, 0) == 0 else { throw error("Reading process count") }
        // Allow process creation between the kernel's size and data calls.
        var records = [kinfo_proc](repeating: kinfo_proc(), count: bytes / MemoryLayout<kinfo_proc>.stride + 32)
        bytes = records.count * MemoryLayout<kinfo_proc>.stride
        let status = records.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &bytes, nil, 0) }
        guard status == 0 else { throw error("Reading process metadata") }
        return records.prefix(bytes / MemoryLayout<kinfo_proc>.stride).map { record in
            var record = record
            let name = withUnsafePointer(to: &record.kp_proc.p_comm) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            return Entry(pid: record.kp_proc.p_pid, parent: record.kp_eproc.e_ppid, group: record.kp_eproc.e_pgid,
                         tty: record.kp_eproc.e_tdev, foregroundGroup: record.kp_eproc.e_tpgid, name: name)
        }
    }

    private static func ttyState(_ device: dev_t) throws -> TTYState? {
        guard let name = devname(device, mode_t(S_IFCHR)) else { return nil }
        let fd = open("/dev/" + String(cString: name), O_RDONLY | O_NOCTTY | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT || errno == ENXIO { return nil } // The terminal closed after the snapshot.
            throw error("Opening terminal metadata")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw error("Reading terminal ownership") }
        guard info.st_uid == getuid(), info.st_rdev == device else { return nil }
        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { throw error("Reading terminal mode") }
        // Foreground PGID is in the kernel snapshot; tcgetpgrp rejects a non-controlling reader on macOS.
        return TTYState(echo: attributes.c_lflag & tcflag_t(ECHO) != 0)
    }

    private static func error(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation + " failed"])
    }
}
