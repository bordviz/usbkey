import Foundation
import CryptoKit
import Security
import IOKit

public enum Command {
    @discardableResult public static func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        let out = Pipe(); let err = Pipe(); p.standardOutput = out; p.standardError = err
        let incoming = Pipe(); p.standardInput = incoming
        try p.run()
        if let input { incoming.fileHandleForWriting.write(input) }
        try incoming.fileHandleForWriting.close()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw KeyError(String(data: errors, encoding: .utf8) ?? "Ошибка команды") }
        return output
    }
}

public struct Volume: Identifiable, Equatable {
    public let url: URL
    public let name: String
    public let binding: Binding
    public var id: String { url.path }
    public init(url: URL, name: String, binding: Binding) { self.url = url; self.name = name; self.binding = binding }
}
public enum Volumes {
    public static func list() -> [Volume] {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey, .volumeNameKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).compactMap { url in
            guard url.path.hasPrefix("/Volumes/"), let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsInternal == false, values.volumeIsLocal == true,
                  values.volumeIsReadOnly == false, let uuid = values.volumeUUIDString else { return nil }
            // Disk images have no USB ancestor and are deliberately excluded.
            guard let info = try? Command.run("/usr/sbin/diskutil", ["info", "-plist", url.path]),
                  let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  let device = plist["DeviceIdentifier"] as? String,
                  let usb = usbIdentity(device) else { return nil }
            return Volume(url: url, name: values.volumeName ?? url.lastPathComponent,
                          binding: Binding(volumeUUID: uuid, serialHash: usb.serialHash))
        }
    }
    struct USBIdentity { let serialHash: String? }
    static func usbIdentity(_ bsd: String) -> USBIdentity? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard service != 0 else { return nil }
        var entry = service
        while entry != 0 {
            let isUSB = IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0
            if isUSB {
                let serial = IORegistryEntryCreateCFProperty(entry, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                IOObjectRelease(entry)
                let hash = serial.flatMap { $0.isEmpty ? nil : Data(SHA256.hash(data: Data($0.utf8))).base64EncodedString() }
                return USBIdentity(serialHash: hash)
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS else { return nil }
            entry = parent
        }
        return nil
    }
}

public enum Vault {
    static let service = "local.usbkey.wrapping-key.v1"
    static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public static func save(_ key: SymmetricKey, id: UUID) throws {
        var q = query(id)
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        q[kSecAttrLabel as String] = "USBKey — \(id.uuidString)"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError("Связка ключей: \(status).") }
    }
    public static func load(_ id: UUID) throws -> SymmetricKey {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { throw KeyError("Не удалось открыть ключ в Связке ключей этого Mac (\(status)).") }
        return SymmetricKey(data: data)
    }
    public static func remove(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}

public struct Registration: Codable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let binding: Binding
    public let publicKey: String
    public let createdAt: Date
}
public final class Store {
    public static let tokenName = ".usbkey-token.json"
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/USBKey")) { self.root = root }
    public func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    public func registrations() throws -> [Registration] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(Registration.self, from: Data(contentsOf: $0)) }.sorted { $0.createdAt < $1.createdAt }
    }
    public func publicURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".pub") }
    public func token(on volume: Volume) throws -> Token {
        let path = volume.url.appendingPathComponent(Self.tokenName)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 16_384 else { throw KeyError("Недопустимый файл токена.") }
        return try JSONDecoder().decode(Token.self, from: Data(contentsOf: path))
    }
    public func create(on volume: Volume) throws -> Registration {
        guard Volumes.list().contains(where: { $0.url == volume.url && $0.binding == volume.binding }) else { throw KeyError("Флешка отключена или изменилась.") }
        let url = volume.url.appendingPathComponent(Self.tokenName)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw KeyError("На флешке уже есть токен. Он не будет перезаписан.") }
        try prepare()
        let id = UUID(); let key = Curve25519.Signing.PrivateKey(); let wrapping = SymmetricKey(size: .bits256)
        let token = try Token.create(id: id, binding: volume.binding, key: key, wrappingKey: wrapping)
        let record = Registration(id: id, name: volume.name, binding: volume.binding, publicKey: token.publicKey, createdAt: Date())
        try Vault.save(wrapping, id: id)
        var tokenWritten = false
        do {
            // O_EXCL semantics: never replace an existing token.
            try JSONEncoder().encode(token).write(to: url, options: [.withoutOverwriting])
            tokenWritten = true
            try Data((record.publicKey + "\n").utf8).write(to: publicURL(id), options: [.atomic])
            try JSONEncoder().encode(record).write(to: root.appendingPathComponent(id.uuidString + ".json"), options: [.atomic])
        } catch {
            Vault.remove(id)
            if tokenWritten { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: publicURL(id))
            throw error
        }
        return record
    }
    public func resolve(_ record: Registration, volumes: [Volume]) throws -> (Token, Volume) {
        let matches = volumes.filter { $0.binding == record.binding }
        guard matches.count == 1, let volume = matches.first else { throw KeyError("Подключите исходную флешку. Носитель отсутствует или обнаружен дубликат UUID.") }
        let token = try self.token(on: volume)
        guard token.id == record.id, token.binding == record.binding, token.publicKey == record.publicKey else { throw KeyError("Токен не соответствует зарегистрированному ключу.") }
        return (token, volume)
    }
    public func configure(repository: URL, record: Registration, helper: URL) throws {
        let git = "/usr/bin/git"
        _ = try Command.run(git, ["-C", repository.path, "rev-parse", "--git-dir"])
        let emailData = try Command.run(git, ["-C", repository.path, "config", "user.email"])
        let email = String(decoding: emailData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !email.contains(where: { $0.isWhitespace || ",*?!\\\"".contains($0) }) else { throw KeyError("Задайте корректный user.email в репозитории.") }
        try prepare()
        let allowed = root.appendingPathComponent(record.id.uuidString + "-" + Data(SHA256.hash(data: Data(email.utf8))).prefix(8).map { String(format: "%02x", $0) }.joined() + ".allowed_signers")
        try Data((email + " " + record.publicKey + "\n").utf8).write(to: allowed, options: [.atomic])
        let settings = [("gpg.format", "ssh"), ("gpg.ssh.program", "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"), ("user.signingkey", publicURL(record.id).path), ("gpg.ssh.allowedSignersFile", allowed.path), ("commit.gpgsign", "true")]
        let names = settings.map { $0.0 }
        let backup = root.appendingPathComponent("git-backup-" + UUID().uuidString + ".backup")
        var previous: [String: [String]] = [:]
        for name in names {
            let result = try? Command.run(git, ["-C", repository.path, "config", "--local", "--null", "--get-all", name])
            previous[name] = result.map { String(decoding: $0, as: UTF8.self).split(separator: "\0").map(String.init) } ?? []
        }
        let backupData: [String: Any] = ["repository": repository.path, "settings": previous]
        try JSONSerialization.data(withJSONObject: backupData, options: [.prettyPrinted, .sortedKeys]).write(to: backup, options: [.atomic])
        do {
            for (name, value) in settings { try Command.run(git, ["-C", repository.path, "config", "--local", "--replace-all", name, value]) }
        } catch {
            for name in names {
                _ = try? Command.run(git, ["-C", repository.path, "config", "--local", "--unset-all", name])
                for value in previous[name] ?? [] { _ = try? Command.run(git, ["-C", repository.path, "config", "--local", "--add", name, value]) }
            }
            throw error
        }
    }
}
