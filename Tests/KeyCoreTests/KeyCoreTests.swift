import XCTest
import CryptoKit
@testable import KeyCore

final class KeyCoreTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("USBKey-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testEncryptionAndBinding() throws {
        let key = Curve25519.Signing.PrivateKey(), wrapping = SymmetricKey(size: .bits256)
        let binding = Binding(volumeUUID: "volume-a", serialHash: "serial-a")
        let token = try Token.create(id: UUID(), binding: binding, key: key, wrappingKey: wrapping)
        let serialized = try JSONEncoder().encode(token)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains(key.rawRepresentation.base64EncodedString()))
        let restored = try JSONDecoder().decode(Token.self, from: serialized)
        XCTAssertEqual(try restored.unlock(binding: binding, wrappingKey: wrapping).rawRepresentation, key.rawRepresentation)
        XCTAssertThrowsError(try restored.unlock(binding: Binding(volumeUUID: "volume-b", serialHash: "serial-a"), wrappingKey: wrapping))
        XCTAssertThrowsError(try restored.unlock(binding: Binding(volumeUUID: "volume-a", serialHash: "serial-b"), wrappingKey: wrapping))
        XCTAssertThrowsError(try restored.unlock(binding: binding, wrappingKey: SymmetricKey(size: .bits256)))
    }
    func testTamperedMetadataAndCiphertextRejected() throws {
        let wrapping = SymmetricKey(size: .bits256)
        let binding = Binding(volumeUUID: "a", serialHash: nil)
        let token = try Token.create(id: UUID(), binding: binding, key: Curve25519.Signing.PrivateKey(), wrappingKey: wrapping)
        let data = try JSONEncoder().encode(token)
        for field in ["id", "publicKey", "encryptedKey"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[field] = field == "id" ? UUID().uuidString : (field == "publicKey" ? "ssh-ed25519 changed" : Data(repeating: 0, count: 60).base64EncodedString())
            let tampered = try JSONDecoder().decode(Token.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try tampered.unlock(binding: binding, wrappingKey: wrapping))
        }
    }
    func testOpenSSHInteroperabilityAndChangedMessageRejected() throws {
        let dir = try temporaryDirectory(), key = Curve25519.Signing.PrivateKey()
        let msg = Data("test commit payload\n".utf8)
        let signature = dir.appendingPathComponent("message.sig"), allowed = dir.appendingPathComponent("allowed")
        try SSHSignature.sign(msg, key: key).write(to: signature)
        try Data(("test@example.com " + SSHSignature.publicKey(key) + "\n").utf8).write(to: allowed)
        let args = ["-Y", "verify", "-f", allowed.path, "-I", "test@example.com", "-n", "git", "-s", signature.path]
        let result = try Command.run("/usr/bin/ssh-keygen", args, input: msg)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("Good"))
        XCTAssertThrowsError(try Command.run("/usr/bin/ssh-keygen", args, input: Data("modified".utf8)))
        var otherNamespace = args; otherNamespace[7] = "file"
        XCTAssertThrowsError(try Command.run("/usr/bin/ssh-keygen", otherNamespace, input: msg))
    }
    func testRealGitCommitVerification() throws {
        let dir = try temporaryDirectory(), key = Curve25519.Signing.PrivateKey()
        try Command.run("/usr/bin/git", ["-C", dir.path, "init", "-q"])
        let tree = String(decoding: try Command.run("/usr/bin/git", ["-C", dir.path, "mktree"], input: Data()), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = "tree \(tree)\nauthor Tester <test@example.com> 1700000000 +0000\ncommitter Tester <test@example.com> 1700000000 +0000\n\nUSBKey integration\n"
        let sig = String(decoding: try SSHSignature.sign(Data(payload.utf8), key: key), as: UTF8.self).trimmingCharacters(in: .newlines)
        let signed = "tree \(tree)\nauthor Tester <test@example.com> 1700000000 +0000\ncommitter Tester <test@example.com> 1700000000 +0000\ngpgsig " + sig.replacingOccurrences(of: "\n", with: "\n ") + "\n\nUSBKey integration\n"
        let hash = String(decoding: try Command.run("/usr/bin/git", ["-C", dir.path, "hash-object", "-t", "commit", "-w", "--stdin"], input: Data(signed.utf8)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = dir.appendingPathComponent("allowed")
        try Data(("test@example.com " + SSHSignature.publicKey(key) + "\n").utf8).write(to: allowed)
        try Command.run("/usr/bin/git", ["-C", dir.path, "-c", "gpg.ssh.allowedSignersFile=" + allowed.path, "verify-commit", hash])
    }
    func testAbsenceAndClonedVolumeRejected() throws {
        let dir = try temporaryDirectory(), store = Store(root: dir.appendingPathComponent("store"))
        let binding = Binding(volumeUUID: "a", serialHash: "serial")
        let record = Registration(id: UUID(), name: "test", binding: binding, publicKey: "public", createdAt: Date())
        XCTAssertThrowsError(try store.resolve(record, volumes: []))
        let clone = Volume(url: dir, name: "clone", binding: Binding(volumeUUID: "b", serialHash: "serial"))
        XCTAssertThrowsError(try store.resolve(record, volumes: [clone]))
        let volume = Volume(url: dir, name: "a", binding: binding)
        XCTAssertThrowsError(try store.resolve(record, volumes: [volume, volume]))
    }
    func testSymlinkTokenRejected() throws {
        let dir = try temporaryDirectory(), store = Store(root: dir.appendingPathComponent("store"))
        let target = dir.appendingPathComponent("other")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(Store.tokenName), withDestinationURL: target)
        XCTAssertThrowsError(try store.token(on: Volume(url: dir, name: "test", binding: Binding(volumeUUID: "a", serialHash: nil))))
    }
    func testRepositoryConfigurationIsLocalAndBackedUp() throws {
        let dir = try temporaryDirectory(), repo = dir.appendingPathComponent("repo with spaces"), root = dir.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Command.run("/usr/bin/git", ["-C", repo.path, "init", "-q"])
        try Command.run("/usr/bin/git", ["-C", repo.path, "config", "user.email", "test@example.com"])
        try Command.run("/usr/bin/git", ["-C", repo.path, "config", "commit.gpgsign", "false"])
        let store = Store(root: root), key = Curve25519.Signing.PrivateKey()
        let record = Registration(id: UUID(), name: "test", binding: Binding(volumeUUID: "a", serialHash: nil), publicKey: SSHSignature.publicKey(key), createdAt: Date())
        try store.configure(repository: repo, record: record, helper: dir.appendingPathComponent("app's folder/usbkey-sign"))
        XCTAssertEqual(String(decoding: try Command.run("/usr/bin/git", ["-C", repo.path, "config", "--local", "gpg.format"]), as: UTF8.self), "ssh\n")
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backups[0])) as? [String: Any])
        XCTAssertEqual((backup["settings"] as? [String: [String]])?["commit.gpgsign"], ["false"])
    }
}
