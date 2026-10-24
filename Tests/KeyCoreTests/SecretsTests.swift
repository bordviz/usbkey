import XCTest
import CryptoKit
@testable import KeyCore

final class SecretsTests: XCTestCase {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uk-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testSecretsEncryptedAndAuthenticated() throws {
        let wrapping = SymmetricKey(size: .bits256), id = UUID(), binding = Binding(volumeUUID: "USB", serialHash: "serial")
        let entry = try SecretEntry(name: "unique label", kind: .password, value: "test-only secret")
        let encrypted = try SecretEnvelope.seal([entry], tokenID: id, binding: binding, key: wrapping)
        let serialized = try JSONEncoder().encode(encrypted)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("unique label"))
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("test-only secret"))
        XCTAssertEqual(try encrypted.open(tokenID: id, binding: binding, key: wrapping).first?.value, entry.value)
        XCTAssertThrowsError(try encrypted.open(tokenID: UUID(), binding: binding, key: wrapping))
        XCTAssertThrowsError(try encrypted.open(tokenID: id, binding: Binding(volumeUUID: "clone", serialHash: "serial"), key: wrapping))
        XCTAssertThrowsError(try encrypted.open(tokenID: id, binding: binding, key: SymmetricKey(size: .bits256)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: serialized) as? [String: Any])
        object["ciphertext"] = Data(repeating: 42, count: 100).base64EncodedString()
        let damaged = try JSONDecoder().decode(SecretEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try damaged.open(tokenID: id, binding: binding, key: wrapping))
    }
    func testSecretStoragePreservesVersionOneTokenAndRejectsSymlink() throws {
        let dir = try temp(), wrapping = SymmetricKey(size: .bits256), id = UUID(), binding = Binding(volumeUUID: "a", serialHash: nil)
        let token = try Token.create(id: id, binding: binding, key: Curve25519.Signing.PrivateKey(), wrappingKey: wrapping)
        let raw = try JSONEncoder().encode(token)
        let tokenURL = dir.appendingPathComponent(Store.tokenName)
        try raw.write(to: tokenURL)
        let store = Store(root: dir.appendingPathComponent("state")), volume = Volume(url: dir, name: "USB", binding: binding)
        let record = Registration(id: id, name: "USB", binding: binding, publicKey: token.publicKey, createdAt: Date())
        XCTAssertEqual(try store.readSecrets(record: record, volume: volume, key: wrapping).count, 0)
        let entry = try SecretEntry(name: "multiline", kind: .token, value: "a\nb\n c")
        try store.writeSecrets([entry], record: record, volume: volume, key: wrapping)
        XCTAssertEqual(try store.readSecrets(record: record, volume: volume, key: wrapping).first?.value, entry.value)
        XCTAssertEqual(try Data(contentsOf: tokenURL), raw)
        let secretsURL = dir.appendingPathComponent(Store.secretsName)
        try FileManager.default.removeItem(at: secretsURL)
        let target = dir.appendingPathComponent("target"); try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: secretsURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.readSecrets(record: record, volume: volume, key: wrapping))
        XCTAssertThrowsError(try store.writeSecrets([entry], record: record, volume: volume, key: wrapping))
        XCTAssertEqual(try String(contentsOf: target), "original")
    }
    func testOpenSSHImportMatchesSystemPublicKey() throws {
        let dir = try temp(), path = dir.appendingPathComponent("fixture")
        try Command.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path.path])
        let key = try OpenSSHKey.decode(String(contentsOf: path))
        let pub = try String(contentsOf: URL(fileURLWithPath: path.path + ".pub")).split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(SSHSignature.publicKey(key), pub)
        let entry = try SecretEntry(name: "imported", kind: .sshKey, value: String(contentsOf: path))
        XCTAssertEqual(entry.publicKey, pub)
    }
    func testEncryptedSSHImportAndInvalidValuesRejected() throws {
        let dir = try temp(), path = dir.appendingPathComponent("fixture")
        try Command.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "fixture-password-not-a-user-secret", "-f", path.path])
        XCTAssertThrowsError(try OpenSSHKey.decode(String(contentsOf: path)))
        XCTAssertThrowsError(try SecretEntry(name: "", kind: .token, value: "x"))
        XCTAssertThrowsError(try SecretEntry(name: "x", kind: .password, value: ""))
        XCTAssertThrowsError(try SecretEntry(name: "x", kind: .sshKey, value: "not a key"))
        XCTAssertThrowsError(try SecretEntry(name: "x", kind: .token, value: String(repeating: "x", count: 65537)))
    }
    func testGeneratedSSHKeyRoundTrips() throws {
        let key = Curve25519.Signing.PrivateKey()
        let entry = try SecretEntry(name: "new", kind: .sshKey, value: "ed25519:" + key.rawRepresentation.base64EncodedString())
        XCTAssertEqual(entry.publicKey, SSHSignature.publicKey(key))
        XCTAssertEqual(try SecretEntry.privateKey(entry.value).rawRepresentation, key.rawRepresentation)
    }
    func testDuplicateEntriesAndLimitsRejected() throws {
        let entry = try SecretEntry(name: "x", kind: .token, value: "test")
        let key = SymmetricKey(size: .bits256), id = UUID(), binding = Binding(volumeUUID: "x", serialHash: nil)
        XCTAssertThrowsError(try SecretEnvelope.seal([entry, entry], tokenID: id, binding: binding, key: key))
        XCTAssertThrowsError(try SecretEnvelope.seal(Array(repeating: entry, count: 101), tokenID: id, binding: binding, key: key))
    }
}
