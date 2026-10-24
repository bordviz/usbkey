import Foundation
import CryptoKit

public enum SecretKind: String, Codable, CaseIterable {
    case token, password, sshKey
    public var title: String { switch self { case .token: return "Токен / текст"; case .password: return "Пароль"; case .sshKey: return "SSH-ключ Ed25519" } }
}
public struct SecretEntry: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public let kind: SecretKind
    public let value: String
    public init(id: UUID = UUID(), name: String, kind: SecretKind, value: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200,
              !value.isEmpty, value.utf8.count <= 65_536 else { throw KeyError("Название обязательно (до 200 байт); значение — от 1 до 65536 байт.") }
        if kind == .sshKey { _ = try Self.privateKey(value) }
        self.id = id; self.name = name; self.kind = kind; self.value = value
    }
    public static func privateKey(_ value: String) throws -> Curve25519.Signing.PrivateKey {
        if value.hasPrefix("ed25519:") {
            guard let data = Data(base64Encoded: String(value.dropFirst(8))), data.count == 32 else { throw KeyError("Некорректный SSH-ключ.") }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        return try OpenSSHKey.decode(value)
    }
    public var publicKey: String? { guard kind == .sshKey, let key = try? Self.privateKey(value) else { return nil }; return SSHSignature.publicKey(key) }
}
public struct SecretSummary: Identifiable {
    public let id: UUID
    public let name: String
    public let kind: SecretKind
    public let publicKey: String?
    public init(_ entry: SecretEntry) { id = entry.id; name = entry.name; kind = entry.kind; publicKey = entry.publicKey }
}
public struct SecretPayload: Codable {
    public var entries: [SecretEntry]
    public var typingEntryID: UUID?
    public init(entries: [SecretEntry] = [], typingEntryID: UUID? = nil) { self.entries = entries; self.typingEntryID = typingEntryID }
    public func validated() throws -> Self {
        guard entries.count <= 100, Set(entries.map(\.id)).count == entries.count else { throw KeyError("Повреждён список записей.") }
        for entry in entries { _ = try SecretEntry(id: entry.id, name: entry.name, kind: entry.kind, value: entry.value) }
        if let id = typingEntryID {
            guard let entry = entries.first(where: { $0.id == id }), entry.kind != .sshKey else { throw KeyError("Некорректная запись для ввода.") }
        }
        return self
    }
}
public struct SecretEnvelope: Codable {
    public let version: Int
    public let tokenID: UUID
    public let binding: Binding
    public let ciphertext: Data
    static func aad(_ tokenID: UUID, _ binding: Binding) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("USBKey/secrets/v1\0".utf8) + Data(tokenID.uuidString.utf8) + (try encoder.encode(binding))
    }
    public static func seal(_ entries: [SecretEntry], tokenID: UUID, binding: Binding, key: SymmetricKey) throws -> Self {
        try sealPayload(SecretPayload(entries: entries), tokenID: tokenID, binding: binding, key: key)
    }
    public static func sealPayload(_ payload: SecretPayload, tokenID: UUID, binding: Binding, key: SymmetricKey) throws -> Self {
        let valid = try payload.validated()
        let sealed = try AES.GCM.seal(JSONEncoder().encode(valid), using: key, authenticating: aad(tokenID, binding))
        guard let data = sealed.combined else { throw KeyError("Не удалось зашифровать записи.") }
        return Self(version: 1, tokenID: tokenID, binding: binding, ciphertext: data)
    }
    public func open(tokenID: UUID, binding: Binding, key: SymmetricKey) throws -> [SecretEntry] {
        try openPayload(tokenID: tokenID, binding: binding, key: key).entries
    }
    public func openPayload(tokenID: UUID, binding: Binding, key: SymmetricKey) throws -> SecretPayload {
        guard version == 1, self.tokenID == tokenID, self.binding == binding else { throw KeyError("Хранилище принадлежит другому ключу.") }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: Self.aad(tokenID, binding))
        // Read the array-only format produced by USBKey 0.2 without rewriting it.
        let payload: SecretPayload
        if let legacy = try? JSONDecoder().decode([SecretEntry].self, from: data) { payload = SecretPayload(entries: legacy) }
        else { payload = try JSONDecoder().decode(SecretPayload.self, from: data) }
        return try payload.validated()
    }
}

extension Store {
    public static let secretsName = ".usbkey-secrets.enc"
    public func readSecrets(record: Registration, volume: Volume, key: SymmetricKey) throws -> [SecretEntry] {
        try readPayload(record: record, volume: volume, key: key).entries
    }
    public func readPayload(record: Registration, volume: Volume, key: SymmetricKey) throws -> SecretPayload {
        let token = try self.token(on: volume)
        guard token.id == record.id, token.binding == volume.binding, record.binding == volume.binding, token.publicKey == record.publicKey else { throw KeyError("Флешка или токен не соответствуют регистрации.") }
        let url = volume.url.appendingPathComponent(Self.secretsName)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 10_000_000 else { throw KeyError("Некорректный файл хранилища.") }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return SecretPayload() }
        return try JSONDecoder().decode(SecretEnvelope.self, from: Data(contentsOf: url)).openPayload(tokenID: record.id, binding: volume.binding, key: key)
    }
    public func writeSecrets(_ entries: [SecretEntry], record: Registration, volume: Volume, key: SymmetricKey) throws {
        var payload = try readPayload(record: record, volume: volume, key: key)
        payload.entries = entries
        if let id = payload.typingEntryID, !entries.contains(where: { $0.id == id && $0.kind != .sshKey }) { payload.typingEntryID = nil }
        try writePayload(payload, record: record, volume: volume, key: key)
    }
    public func writePayload(_ payload: SecretPayload, record: Registration, volume: Volume, key: SymmetricKey) throws {
        // Verify the original token, including its authentication tag, before writing.
        let token = try self.token(on: volume)
        guard token.id == record.id, token.publicKey == record.publicKey, record.binding == volume.binding else { throw KeyError("Несоответствие носителя.") }
        _ = try token.unlock(binding: volume.binding, wrappingKey: key)
        let url = volume.url.appendingPathComponent(Self.secretsName)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType != .typeRegular { throw KeyError("Файл хранилища не должен быть ссылкой.") }
        let envelope = try SecretEnvelope.sealPayload(payload, tokenID: record.id, binding: volume.binding, key: key)
        try JSONEncoder().encode(envelope).write(to: url, options: [.atomic])
    }
}

public struct SSHReader {
    public let data: Data
    public private(set) var offset = 0
    public init(_ data: Data) { self.data = Data(data) }
    public var finished: Bool { offset == data.count }
    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw KeyError("Повреждён пакет SSH.") }
        defer { offset += count }; return data.subdata(in: offset..<offset + count)
    }
    public mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    public mutating func word() throws -> UInt32 { try bytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    public mutating func field() throws -> Data { try bytes(Int(word())) }
    public mutating func string() throws -> String { let field = try field(); guard let value = String(data: field, encoding: .utf8) else { throw KeyError("Некорректная строка SSH.") }; return value }
}
public enum OpenSSHKey {
    public static func decode(_ text: String) throws -> Curve25519.Signing.PrivateKey {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        guard lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----", lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let blob = Data(base64Encoded: lines.dropFirst().dropLast().joined()), blob.count <= 65_536 else { throw KeyError("Нужен OpenSSH private key Ed25519 без пароля. RSA/ECDSA и защищённые паролем файлы пока не поддерживаются.") }
        var reader = SSHReader(blob)
        guard try reader.bytes(15) == Data("openssh-key-v1\0".utf8), try reader.string() == "none", try reader.string() == "none", try reader.field().isEmpty, try reader.word() == 1 else { throw KeyError("Импортируется один OpenSSH Ed25519 без пароля. Для нового ключа нажмите «Сгенерировать».") }
        let publicBlob = try reader.field()
        var inner = SSHReader(try reader.field())
        guard reader.finished, try inner.word() == inner.word(), try inner.string() == "ssh-ed25519" else { throw KeyError("Повреждённый или неподдерживаемый SSH-ключ.") }
        let publicBytes = try inner.field(), secret = try inner.field()
        _ = try inner.string() // comment
        guard secret.count == 64 else { throw KeyError("Некорректный Ed25519 ключ.") }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
        guard publicBytes == key.publicKey.rawRepresentation, secret.suffix(32) == publicBytes, publicBlob == SSHSignature.publicBlob(key) else { throw KeyError("SSH-ключ не прошёл проверку.") }
        var pad: UInt8 = 1
        while !inner.finished { guard try inner.byte() == pad else { throw KeyError("Повреждено дополнение SSH-ключа.") }; pad &+= 1 }
        return key
    }
}
