import XCTest
import CryptoKit
@testable import KeyCore

final class TypingTests: XCTestCase {
    func testUnicodeChunksDoNotSplitSurrogatesOrChangeValue() throws {
        let text = String(repeating: "Пароль 👩‍💻 日本語 ", count: 20)
        let chunks = try TypingPlan.chunks(text)
        XCTAssertEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), text)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 16)
            if let last = chunk.last { XCTAssertFalse((0xD800...0xDBFF).contains(last)) }
            if let first = chunk.first { XCTAssertFalse((0xDC00...0xDFFF).contains(first)) }
        }
    }
    func testEachEventContainsExactlyOneUnicodeScalar() throws {
        let text = "Az1!Пароль😀👩‍💻"
        let chunks = try TypingPlan.chunks(text)
        XCTAssertEqual(chunks.count, text.unicodeScalars.count)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 2)
            XCTAssertEqual(String(decoding: chunk, as: UTF16.self).unicodeScalars.count, 1)
        }
        XCTAssertEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), text)
    }
    func testApplicationDestinationDoesNotRequireAnAccessibilityField() {
        // Only process identity participates: terminal/canvas AX roles are irrelevant.
        XCTAssertEqual(TypingDestination.choose(frontmostPID: 200, previousPID: 300, ownPID: 100), 200)
        XCTAssertEqual(TypingDestination.choose(frontmostPID: 100, previousPID: 200, ownPID: 100), 200)
        XCTAssertEqual(TypingDestination.choose(frontmostPID: nil, previousPID: 200, ownPID: 100), 200)
        XCTAssertNil(TypingDestination.choose(frontmostPID: 100, previousPID: 100, ownPID: 100))
        XCTAssertNil(TypingDestination.choose(frontmostPID: nil, previousPID: nil, ownPID: 100))
        XCTAssertNil(TypingDestination.choose(frontmostPID: 0, previousPID: -1, ownPID: 100))
    }
    func testControlKeysAndEmptyValuesNeverBecomeTypingPlans() throws {
        for value in ["", "abc\n", "a\rb", "a\tb", "a\u{1B}", "a\u{7F}", "a\u{2028}b", String(repeating: "x", count: 65_537)] {
            XCTAssertThrowsError(try TypingPlan.chunks(value))
        }
        XCTAssertNoThrow(try TypingPlan.chunks("a!@#$%^&*()_+-=[]{}:;\"'<>?/\\ café"))
    }
    @MainActor func testFocusOrDeviceLossStopsBeforeNextChunk() async throws {
        let chunks = try TypingPlan.chunks(String(repeating: "x", count: 60))
        var allowed = true, sent = 0
        do {
            try await TypingRunner.run(chunks: chunks, isAllowed: { allowed }, emit: { _ in sent += 1; allowed = false }, wait: {})
            XCTFail("Focus/device loss must stop typing")
        } catch { XCTAssertEqual(sent, 1) }
        sent = 0
        do { try await TypingRunner.run(chunks: chunks, isAllowed: { false }, emit: { _ in sent += 1 }, wait: {}); XCTFail("Missing permission/focus must emit nothing") }
        catch { XCTAssertEqual(sent, 0) }
    }
    @MainActor func testCancellationDoesNotEmitFollowingChunks() async throws {
        var sent = 0
        do {
            try await TypingRunner.run(chunks: [[65], [66], [67]], isAllowed: { true }, emit: { _ in sent += 1 }, wait: { throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual(sent, 1) }
    }
    func testTypingDefaultEncryptedAndBoundToToken() throws {
        let entry = try SecretEntry(name: "Password", kind: .password, value: "fixture")
        let other = try SecretEntry(name: "Token", kind: .token, value: "token")
        let id = UUID(), key = SymmetricKey(size: .bits256), binding = Binding(volumeUUID: "a", serialHash: nil)
        let envelope = try SecretEnvelope.sealPayload(SecretPayload(entries: [entry, other], typingEntryID: entry.id), tokenID: id, binding: binding, key: key)
        let raw = try JSONEncoder().encode(envelope)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(entry.id.uuidString))
        XCTAssertEqual(try envelope.openPayload(tokenID: id, binding: binding, key: key).typingEntryID, entry.id)
        XCTAssertThrowsError(try envelope.openPayload(tokenID: UUID(), binding: binding, key: key))
        XCTAssertThrowsError(try SecretEnvelope.sealPayload(SecretPayload(entries: [entry], typingEntryID: other.id), tokenID: id, binding: binding, key: key))
        let ssh = try SecretEntry(name: "SSH", kind: .sshKey, value: "ed25519:" + Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
        XCTAssertThrowsError(try SecretEnvelope.sealPayload(SecretPayload(entries: [ssh], typingEntryID: ssh.id), tokenID: id, binding: binding, key: key))
    }
    func testLegacyEncryptedArrayStillOpensWithoutInventingDefault() throws {
        let entry = try SecretEntry(name: "Legacy", kind: .token, value: "fixture"), id = UUID(), key = SymmetricKey(size: .bits256), binding = Binding(volumeUUID: "legacy", serialHash: nil)
        let ciphertext = try XCTUnwrap(AES.GCM.seal(JSONEncoder().encode([entry]), using: key, authenticating: SecretEnvelope.aad(id, binding)).combined)
        let old = SecretEnvelope(version: 1, tokenID: id, binding: binding, ciphertext: ciphertext)
        let payload = try old.openPayload(tokenID: id, binding: binding, key: key)
        XCTAssertEqual(payload.entries.first?.value, entry.value); XCTAssertNil(payload.typingEntryID)
    }
    func testStoragePreservesDefaultAcrossEditsAndClearsItOnDeletion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uk-default-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID(), key = SymmetricKey(size: .bits256), binding = Binding(volumeUUID: "flash", serialHash: "serial")
        let token = try Token.create(id: id, binding: binding, key: Curve25519.Signing.PrivateKey(), wrappingKey: key)
        try JSONEncoder().encode(token).write(to: dir.appendingPathComponent(Store.tokenName))
        let record = Registration(id: id, name: "fixture", binding: binding, publicKey: token.publicKey, createdAt: Date())
        let volume = Volume(url: dir, name: "fixture", binding: binding), store = Store(root: dir.appendingPathComponent("state"))
        let first = try SecretEntry(name: "first", kind: .password, value: "fixture"), second = try SecretEntry(name: "second", kind: .token, value: "fixture2")
        try store.writePayload(SecretPayload(entries: [first], typingEntryID: first.id), record: record, volume: volume, key: key)
        try store.writeSecrets([first, second], record: record, volume: volume, key: key)
        XCTAssertEqual(try store.readPayload(record: record, volume: volume, key: key).typingEntryID, first.id)
        try store.writeSecrets([second], record: record, volume: volume, key: key)
        XCTAssertNil(try store.readPayload(record: record, volume: volume, key: key).typingEntryID)
    }
    func testShortcutRequiresModifierAndRoundTrips() throws {
        let value = Shortcut.suggested
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(value)), value)
        XCTAssertThrowsError(try Shortcut(keyCode: 40, modifiers: 0, label: "K"))
        XCTAssertThrowsError(try Shortcut(keyCode: 40, modifiers: 512, label: "⇧K"))
        XCTAssertThrowsError(try Shortcut(keyCode: 4000, modifiers: 256, label: "bad"))
        XCTAssertThrowsError(try Shortcut(keyCode: 40, modifiers: 1, label: "bad"))
    }
}
