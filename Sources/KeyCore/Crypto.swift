import Foundation
import CryptoKit

public struct KeyError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum SSHSignature {
    static func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func field(_ value: Data) -> Data { word(UInt32(value.count)) + value }
    static func field(_ value: String) -> Data { field(Data(value.utf8)) }
    public static func publicBlob(_ key: Curve25519.Signing.PrivateKey) -> Data {
        field("ssh-ed25519") + field(key.publicKey.rawRepresentation)
    }
    public static func publicKey(_ key: Curve25519.Signing.PrivateKey) -> String {
        "ssh-ed25519 " + publicBlob(key).base64EncodedString()
    }
    public static func fingerprint(_ publicKey: String) -> String {
        let parts = publicKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "Invalid" }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    public static func sign(_ message: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let fields = field("git") + field("") + field("sha512")
        let payload = Data("SSHSIG".utf8) + fields + field(Data(SHA512.hash(data: message)))
        let signature = field("ssh-ed25519") + field(try key.signature(for: payload))
        let blob = Data("SSHSIG".utf8) + word(1) + field(publicBlob(key)) + fields + field(signature)
        let base64 = Array(blob.base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: 76).map { String(base64[$0..<min($0 + 76, base64.count)]) }
        return Data(("-----BEGIN SSH SIGNATURE-----\n" + lines.joined(separator: "\n") + "\n-----END SSH SIGNATURE-----\n").utf8)
    }
}

public struct Binding: Codable, Equatable {
    public let volumeUUID: String
    public let serialHash: String?
    public init(volumeUUID: String, serialHash: String?) { self.volumeUUID = volumeUUID; self.serialHash = serialHash }
}
public struct Token: Codable {
    public let version: Int
    public let id: UUID
    public let binding: Binding
    public let publicKey: String
    public let encryptedKey: Data
    struct Header: Codable { let version: Int; let id: UUID; let binding: Binding; let publicKey: String }
    static func aad(id: UUID, binding: Binding, publicKey: String) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Header(version: 1, id: id, binding: binding, publicKey: publicKey))
    }
    public static func create(id: UUID, binding: Binding, key: Curve25519.Signing.PrivateKey, wrappingKey: SymmetricKey) throws -> Token {
        let pub = SSHSignature.publicKey(key)
        let sealed = try AES.GCM.seal(key.rawRepresentation, using: wrappingKey, authenticating: aad(id: id, binding: binding, publicKey: pub))
        guard let combined = sealed.combined else { throw KeyError("Не удалось зашифровать ключ.") }
        return Token(version: 1, id: id, binding: binding, publicKey: pub, encryptedKey: combined)
    }
    public func unlock(binding actual: Binding, wrappingKey: SymmetricKey) throws -> Curve25519.Signing.PrivateKey {
        guard version == 1, actual == binding else { throw KeyError("Носитель не соответствует привязке ключа.") }
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: encryptedKey), using: wrappingKey, authenticating: Self.aad(id: id, binding: binding, publicKey: publicKey))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        guard SSHSignature.publicKey(key) == publicKey else { throw KeyError("Открытый ключ повреждён.") }
        return key
    }
}
