import XCTest
import CryptoKit
import Darwin
@testable import KeyCore

final class AgentTests: XCTestCase {
    func auth(_ key: Curve25519.Signing.PrivateKey, user: String = "tester") -> Data {
        SSHSignature.field(Data(repeating: 1, count: 32)) + Data([50]) + SSHSignature.field(user) + SSHSignature.field("ssh-connection") + SSHSignature.field("publickey") + Data([1]) + SSHSignature.field("ssh-ed25519") + SSHSignature.field(SSHSignature.publicBlob(key))
    }
    func request(_ key: Curve25519.Signing.PrivateKey, data: Data, flags: UInt32 = 0) -> Data {
        Data([13]) + SSHSignature.field(SSHSignature.publicBlob(key)) + SSHSignature.field(data) + SSHSignature.word(flags)
    }
    func testAgentWireSignatureAndIdentityListing() throws {
        let key = Curve25519.Signing.PrivateKey(), payload = auth(Curve25519.Signing.PrivateKey())
        let listing = AgentProtocol.reply(Data([11]), identities: { [AgentIdentity(blob: SSHSignature.publicBlob(key), comment: "USB fixture")] }, sign: { _, _ in Data() })
        var list = SSHReader(listing)
        XCTAssertEqual(try list.byte(), 12); XCTAssertEqual(try list.word(), 1)
        XCTAssertEqual(try list.field(), SSHSignature.publicBlob(key)); XCTAssertEqual(try list.string(), "USB fixture"); XCTAssertTrue(list.finished)
        let data = auth(key)
        let response = AgentProtocol.reply(request(key, data: data), identities: { [] }, sign: { blob, message in
            XCTAssertEqual(blob, SSHSignature.publicBlob(key)); return try key.signature(for: message)
        })
        var r = SSHReader(response)
        XCTAssertEqual(try r.byte(), 14)
        var signature = SSHReader(try r.field())
        XCTAssertEqual(try signature.string(), "ssh-ed25519")
        XCTAssertTrue(key.publicKey.isValidSignature(try signature.field(), for: data))
        XCTAssertTrue(r.finished); XCTAssertTrue(signature.finished)
        XCTAssertThrowsError(try AgentProtocol.authenticationUser(payload, publicBlob: SSHSignature.publicBlob(key)))
    }
    func testAgentRejectsArbitrarySigningCancellationAndUnsupportedOperations() throws {
        let key = Curve25519.Signing.PrivateKey()
        var calls = 0
        let signer: (Data, Data) throws -> Data = { _, message in calls += 1; return try key.signature(for: message) }
        XCTAssertEqual(AgentProtocol.reply(request(key, data: Data("arbitrary data".utf8)), identities: { [] }, sign: signer), Data([5]))
        XCTAssertEqual(AgentProtocol.reply(request(key, data: auth(key), flags: 2), identities: { [] }, sign: signer), Data([5]))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(AgentProtocol.reply(request(key, data: auth(key)), identities: { [] }, sign: { _, _ in throw KeyError("cancelled/unplugged") }), Data([5]))
        for code: UInt8 in [17, 18, 19, 22, 25, 255] { XCTAssertEqual(AgentProtocol.reply(Data([code]), identities: { [] }, sign: signer), Data([5])) }
        XCTAssertEqual(AgentProtocol.reply(Data([27]), identities: { [] }, sign: signer), Data([28]))
        XCTAssertEqual(AgentProtocol.reply(Data([13, 0, 0, 0, 255]), identities: { [] }, sign: signer), Data([5]))
        XCTAssertThrowsError(try AgentProtocol.authenticationUser(auth(key, user: "bad\nuser"), publicBlob: SSHSignature.publicBlob(key)))
    }
    func testActualOpenSSHClientCanListKeysFromUnixSocket() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uka-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("agent.sock").path, key = Curve25519.Signing.PrivateKey()
        let server = AgentServer(path: path) { message in AgentProtocol.reply(message, identities: { [AgentIdentity(blob: SSHSignature.publicBlob(key), comment: "fixture")] }, sign: { _, data in try key.signature(for: data) }) }
        try server.start(); defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
        let other = AgentServer(path: path) { _ in Data([5]) }
        XCTAssertThrowsError(try other.start())
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add"); process.arguments = ["-L"]
        var env = ProcessInfo.processInfo.environment; env["SSH_AUTH_SOCK"] = path; process.environment = env
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), SSHSignature.publicKey(key) + " fixture")
        server.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
