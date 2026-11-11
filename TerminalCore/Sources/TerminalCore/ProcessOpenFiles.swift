//
//  ProcessOpenFiles.swift
//  TerminalCore
//

import Darwin
import Foundation

/// Paths of the regular files a process has open, from kernel metadata.
///
/// libproc lists the descriptor table with `PROC_PIDLISTFDS`, then resolves
/// each vnode descriptor with `PROC_PIDFDVNODEPATHINFO`. Directories, ttys,
/// pipes, and sockets are skipped: callers look for files an agent holds open
/// for the life of a session, and a terminal's own tty would only be noise.
/// Same-user processes only, which is every process Terminal spawns. Empty
/// when the table cannot be read, including when the process has exited.
public nonisolated func processOpenFilePaths(pid: pid_t) -> [String] {
    guard pid > 0 else { return [] }
    let entrySize = MemoryLayout<proc_fdinfo>.stride
    let reported = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard reported > 0 else { return [] }

    // The kernel sizes the table to the process's allocated descriptors, not
    // the ones in use, and a runaway process can hold tens of thousands. The
    // files a caller is after are opened early, so a cap loses nothing real
    // and bounds the per-fd syscalls below.
    let capacity = min(Int(reported) / entrySize + 16, 4096)
    var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
    let filled = entries.withUnsafeMutableBytes { buffer in
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return [] }

    var paths: [String] = []
    let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    for entry in entries.prefix(Int(filled) / entrySize)
    where entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var info = vnode_fdinfowithpath()
        guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize)
            == infoSize,
            info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT == S_IFREG
        else { continue }
        // `vip_path` is a fixed `MAXPATHLEN` tuple the kernel NUL-terminates,
        // so its buffer is never empty and the base address always exists.
        let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !path.isEmpty { paths.append(path) }
    }
    return paths
}

/// When a process started, from kernel metadata.
///
/// Pairs with a timestamp another program recorded: a Codex thread created
/// before its TUI was launched cannot be that TUI's conversation. Same-user
/// processes only; nil once the process has exited.
public nonisolated func processStartDate(pid: pid_t) -> Date? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Date(
        timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    )
}

/// The parent of a process, from kernel metadata. Same-user processes only;
/// nil once the process has exited, and for launchd itself.
public nonisolated func processParentPID(pid: pid_t) -> pid_t? {
    guard pid > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let parent = pid_t(info.pbi_ppid)
    return parent > 0 ? parent : nil
}
