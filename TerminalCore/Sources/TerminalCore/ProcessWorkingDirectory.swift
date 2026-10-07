//
//  ProcessWorkingDirectory.swift
//  TerminalCore
//

import Darwin
import Foundation

/// A process's current working directory, read from kernel metadata.
///
/// A backend that reports OSC 7 tells Terminal where the shell thinks it is, which
/// is authoritative and free. This is the fallback while a backend is waiting
/// for its first report, and the backstop for shells with no OSC 7 integration.
public func processWorkingDirectory(pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
        return nil
    }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
}

/// The executable a process is running, from kernel metadata.
///
/// Agent recognition reads this rather than tab titles or shell command text,
/// both of which are user-controlled terminal output. The buffer is
/// `PROC_PIDPATHINFO_MAXSIZE`, a C arithmetic macro Swift does not import.
public nonisolated func processExecutablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

/// A process's argument vector, from kernel metadata.
///
/// `KERN_PROCARGS2` hands back a counted blob: the argument count, then the
/// executable path, then NUL padding, then the arguments themselves. Only
/// same-user processes are readable, which is every process Terminal spawns.
///
/// The companion to ``processExecutablePath(pid:)`` for script-backed CLIs:
/// macOS reports `node` or `python` as their image, while argv still names
/// the script the shell launched.
public nonisolated func processArguments(pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }

    let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    guard count > 0 else { return nil }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }

    var arguments: [String] = []
    var start = index
    while index < size, arguments.count < count {
        if buffer[index] == 0 {
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            start = index + 1
        }
        index += 1
    }
    return arguments.count == count ? arguments : nil
}
