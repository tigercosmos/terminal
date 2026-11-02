//
//  RegularFilePrefixTests.swift
//  TerminalCore
//

import Darwin
import Foundation
import Testing

@testable import TerminalCore

/// Terminal reads files other processes write by names it finds on disk. A
/// FIFO or device planted under such a name must not hang the app, which a
/// plain open of a writerless FIFO would do indefinitely; if this regresses,
/// the FIFO test hangs rather than fails.
struct RegularFilePrefixTests {
    @Test func aRegularFileYieldsAtMostThePrefix() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file.txt")
        try Data("hello, world".utf8).write(to: url)

        #expect(readRegularFilePrefix(at: url, maxBytes: 5) == Data("hello".utf8))
        #expect(readRegularFilePrefix(at: url, maxBytes: 1024) == Data("hello, world".utf8))
        #expect(readRegularFilePrefix(at: url, maxBytes: 0) == Data())
    }

    @Test func aSymlinkToARegularFileIsFollowed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        try Data("linked".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(readRegularFilePrefix(at: link, maxBytes: 64) == Data("linked".utf8))
    }

    @Test func aFIFOReturnsNilWithoutBlocking() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("rollout.jsonl")
        try #require(mkfifo(fifo.path, 0o600) == 0)

        #expect(readRegularFilePrefix(at: fifo, maxBytes: 64) == nil)
    }

    @Test func aDirectoryOrMissingPathReturnsNil() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(readRegularFilePrefix(at: directory, maxBytes: 64) == nil)
        #expect(readRegularFilePrefix(
            at: directory.appendingPathComponent("missing"), maxBytes: 64
        ) == nil)
        #expect(readRegularFilePrefix(at: URL(fileURLWithPath: "/dev/zero"), maxBytes: 64) == nil)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
