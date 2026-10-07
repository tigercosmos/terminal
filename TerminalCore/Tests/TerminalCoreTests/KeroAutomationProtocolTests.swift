//
//  KeroAutomationProtocolTests.swift
//  TerminalCore
//

import Darwin
import Foundation
import Testing

@testable import TerminalCore

/// The socket every `terminal +pane` and `terminal +agent` call goes through.
/// Each test runs its own server on a socket in the temporary directory.
struct KeroAutomationProtocolTests {
    /// Short on purpose: a socket path must fit `sun_path`'s 104 bytes, and the
    /// per-user temporary directory already takes about half of that.
    private func socketPath() -> String {
        NSTemporaryDirectory() + "ka-\(UUID().uuidString.prefix(8)).sock"
    }

    private func request(
        _ method: String,
        params: [String: KeroJSONValue] = [:]
    ) -> KeroAutomationRequest {
        KeroAutomationRequest(
            version: 1,
            id: UUID().uuidString,
            method: method,
            token: "token",
            terminalID: UUID().uuidString,
            params: params
        )
    }

    @Test func aRequestAndItsReplyRoundTrip() throws {
        let path = socketPath()
        let server = try KeroAutomationSocketServer(path: path) { request, reply in
            reply(.success(id: request.id, result: .object([
                "method": .string(request.method),
                "echo": request.params["text"] ?? .null,
            ])))
        }
        defer { withExtendedLifetime(server) {} }

        let sent = request("pane.read", params: ["text": .string("héllo\nworld")])
        let response = try KeroAutomationSocketServer.exchange(path: path, request: sent)
        #expect(response.ok)
        #expect(response.id == sent.id)
        #expect(response.result?.objectValue?["method"]?.stringValue == "pane.read")
        #expect(response.result?.objectValue?["echo"]?.stringValue == "héllo\nworld")
    }

    /// Only the owner may connect: the capability token is the second check,
    /// not the only one.
    @Test func theSocketIsPrivateToItsOwner() throws {
        let path = socketPath()
        let server = try KeroAutomationSocketServer(path: path) { request, reply in
            reply(.success(id: request.id, result: .null))
        }
        defer { withExtendedLifetime(server) {} }

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func theSocketFileGoesAwayWithTheServer() throws {
        let path = socketPath()
        var server: KeroAutomationSocketServer? = try KeroAutomationSocketServer(path: path) {
            request, reply in reply(.success(id: request.id, result: .null))
        }
        #expect(FileManager.default.fileExists(atPath: path))
        server = nil
        _ = server
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func malformedInputIsAnsweredNotDropped() throws {
        let path = socketPath()
        let server = try KeroAutomationSocketServer(path: path) { request, reply in
            reply(.success(id: request.id, result: .null))
        }
        defer { withExtendedLifetime(server) {} }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        let garbage = Array("not json\n".utf8)
        _ = write(descriptor, garbage, garbage.count)

        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = read(descriptor, &buffer, buffer.count)
        #expect(count > 0)
        let line = Data(buffer[..<max(count, 0)]).split(separator: 0x0A).first ?? Data()
        let response = try JSONDecoder().decode(KeroAutomationResponse.self, from: line)
        #expect(!response.ok)
        #expect(response.error?.code == "invalid_request")
    }

    @Test func connectingToNothingFailsWithAReason() {
        #expect(throws: KeroAutomationWireError.self) {
            _ = try KeroAutomationSocketServer.exchange(
                path: socketPath(), request: request("protocol.info"), timeout: 1
            )
        }
    }

    /// A read's reply has to fit the socket's message limit whatever script
    /// fills the grid, and the lines a reader is waiting for are the last.
    @Test func aLargeReadKeepsItsNewestLinesWithinTheLimit() {
        let line = String(repeating: "漢", count: 2_000)  // 6,000 bytes
        let text = (1...500).map { "\($0) \(line)" }.joined(separator: "\n")
        #expect(text.utf8.count > KeroAutomationSocketServer.maximumReadBytes)

        let bounded = KeroAutomationSocketServer.newestLines(
            of: text, fittingIn: KeroAutomationSocketServer.maximumReadBytes
        )
        #expect(bounded.truncated)
        #expect(bounded.text.utf8.count <= KeroAutomationSocketServer.maximumReadBytes)
        #expect(bounded.text.hasSuffix("500 \(line)"))
        #expect(bounded.text.split(separator: "\n").allSatisfy { $0.hasSuffix(line) })
    }

    @Test func aReadWithinTheLimitIsUntouched() {
        let bounded = KeroAutomationSocketServer.newestLines(of: "a\nb", fittingIn: 3)
        #expect(bounded.text == "a\nb")
        #expect(!bounded.truncated)
        let tail = KeroAutomationSocketServer.newestLines(of: "abcdef", fittingIn: 4)
        #expect(tail.text == "cdef")
        #expect(tail.truncated)
    }

    /// `true` must not come back as the number 1, nor a numeric string as a
    /// number: the router reads flags and counts out of the same params.
    @Test func jsonValuesKeepTheirTypes() throws {
        let data = Data(#"{"flag":true,"count":3,"name":"3","list":[null,1.5]}"#.utf8)
        let value = try JSONDecoder().decode(KeroJSONValue.self, from: data)
        let object = try #require(value.objectValue)
        #expect(object["flag"]?.boolValue == true)
        #expect(object["count"]?.intValue == 3)
        #expect(object["name"]?.stringValue == "3")
        #expect(object["name"]?.intValue == nil)
        #expect(object["list"]?.arrayValue == [.null, .number(1.5)])
        #expect(KeroJSONValue.number(1.5).intValue == nil)
    }
}
