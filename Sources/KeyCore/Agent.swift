import Foundation
import CryptoKit
import Darwin

public struct AgentIdentity {
    public let blob: Data
    public let comment: String
    public init(blob: Data, comment: String) { self.blob = blob; self.comment = comment }
}
public enum AgentProtocol {
    // Accept only public-key user authentication, never an arbitrary signing oracle.
    public static func authenticationUser(_ data: Data, publicBlob: Data) throws -> String {
        var r = SSHReader(data)
        let session = try r.field()
        guard (16...128).contains(session.count), try r.byte() == 50 else { throw KeyError("Не является SSH-аутентификацией.") }
        let user = try r.string()
        guard !user.isEmpty, user.utf8.count <= 256, !user.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }),
              try r.string() == "ssh-connection", try r.string() == "publickey", try r.byte() == 1,
              try r.string() == "ssh-ed25519", try r.field() == publicBlob, r.finished else { throw KeyError("Неподдерживаемый запрос SSH-аутентификации.") }
        return user
    }
    public static func reply(_ message: Data, identities: () throws -> [AgentIdentity], sign: (Data, Data) throws -> Data) -> Data {
        do {
            var r = SSHReader(message)
            switch try r.byte() {
            case 11:
                guard r.finished else { return Data([5]) }
                let keys = try identities()
                guard keys.count <= 100 else { return Data([5]) }
                return Data([12]) + SSHSignature.word(UInt32(keys.count)) + keys.reduce(Data()) { $0 + SSHSignature.field($1.blob) + SSHSignature.field($1.comment) }
            case 13:
                let blob = try r.field(), data = try r.field()
                guard try r.word() == 0, r.finished else { return Data([5]) }
                _ = try authenticationUser(data, publicBlob: blob)
                let signature = try sign(blob, data)
                guard signature.count == 64 else { return Data([5]) }
                return Data([14]) + SSHSignature.field(SSHSignature.field("ssh-ed25519") + SSHSignature.field(signature))
            case 27: return Data([28]) // No session-binding/destination-constrained extensions advertised.
            default: return Data([5]) // No add/remove/export/forwarding or mutation operations.
            }
        } catch { return Data([5]) }
    }
}

public final class AgentServer {
    private let path: String
    private let handler: (Data) -> Data
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private let slots = DispatchSemaphore(value: 16)
    public init(path: String, handler: @escaping (Data) -> Data) { self.path = path; self.handler = handler }
    deinit { stop() }
    private var running: Bool { lock.lock(); defer { lock.unlock() }; return descriptor >= 0 }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw KeyError("Слишком длинный путь к SSH-сокету.") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        return address
    }
    public func start() throws {
        guard !running else { return }
        var addr = try Self.address(path)
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw KeyError("Не удалось проверить SSH-сокет.") }
            let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let errorCode = errno; close(probe)
            guard result != 0, errorCode == ECONNREFUSED else { throw KeyError("SSH-сокет уже занят другим экземпляром USBKey.") }
            guard unlink(path) == 0 else { throw KeyError("Не удалось удалить устаревший SSH-сокет.") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KeyError("Не удалось создать SSH-сокет.") }
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(fd); throw KeyError("Не удалось привязать SSH-сокет (\(errno)).") }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); unlink(path); throw KeyError("Не удалось открыть SSH-агент.") }
        lock.lock(); descriptor = fd; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            while self.running {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), self.slots.wait(timeout: .now()) == .success else { close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { close(client); return }
                    defer { close(client); self.slots.signal() }
                    var timeout = timeval(tv_sec: 60, tv_usec: 0)
                    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var one: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    while self.running {
                        guard let header = Self.read(client, count: 4) else { break }
                        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        guard count > 0, count <= 262_144, let packet = Self.read(client, count: Int(count)) else { break }
                        let response = self.handler(packet)
                        guard Self.write(client, data: SSHSignature.word(UInt32(response.count)) + response) else { break }
                    }
                }
            }
        }
    }
    public func stop() {
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); unlink(path) }
    }
    static func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count); var offset = 0
        while offset < count {
            let amount = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { return nil }; offset += amount
        }
        return data
    }
    static func write(_ fd: Int32, data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { return false }; offset += amount
        }
        return true
    }
}
