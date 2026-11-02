//
//  RegularFilePrefix.swift
//  TerminalCore
//

import Darwin
import Foundation

/// The first `maxBytes` of a regular file, or nil for anything else.
///
/// For files another process writes and Terminal finds by name, such as an
/// agent's rollout. A FIFO, socket, or device planted under a name Terminal
/// looks for would make an ordinary open or read block the caller, which is
/// usually the main actor. The file is opened `O_NONBLOCK` (an open of a FIFO
/// with no writer then returns at once) and checked with `fstat` on that same
/// descriptor before any read, so nothing can be swapped in between the check
/// and the read. Symlinks are followed: the type that matters is the target's.
public nonisolated func readRegularFilePrefix(at url: URL, maxBytes: Int) -> Data? {
    guard maxBytes >= 0 else { return nil }
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
        return nil
    }

    var data = Data(count: maxBytes)
    var filled = 0
    while filled < maxBytes {
        let count = data.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress! + filled, maxBytes - filled)
        }
        if count > 0 {
            filled += count
        } else if count == 0 {
            break
        } else if errno != EINTR {
            return nil
        }
    }
    return data.prefix(filled)
}
