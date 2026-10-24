import AppKit
import Combine
import CryptoKit
import KeyCore
import LocalAuthentication

@MainActor final class Model: ObservableObject {
    @Published var volumes: [Volume] = []
    @Published var records: [Registration] = []
    @Published var selectedVolume = ""
    @Published var selectedKey: UUID? = UserDefaults.standard.string(forKey: "selectedKey").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(selectedKey?.uuidString, forKey: "selectedKey") }
    }
    @Published var typingEntryID: UUID?
    @Published var typingMessage = ""
    @Published var typingFailed = false
    @Published var keyboardPermission = KeyboardTyper.permitted
    @Published var accessibilityPermission = KeyboardTyper.accessibilityTrusted
    @Published private(set) var permissionRestartSuggested = false
    private var permissionTracker = PermissionRestartTracker(initial: InputPermissionSnapshot(posting: KeyboardTyper.permitted, accessibility: KeyboardTyper.accessibilityTrusted))
    @Published var confirmEveryTyping = (UserDefaults.standard.object(forKey: "confirmEveryTyping") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(confirmEveryTyping, forKey: "confirmEveryTyping") }
    }
    @Published var shortcutEnabled = UserDefaults.standard.bool(forKey: "shortcutEnabled") {
        didSet { UserDefaults.standard.set(shortcutEnabled, forKey: "shortcutEnabled") }
    }
    @Published var shortcut: Shortcut = UserDefaults.standard.data(forKey: "typingShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .suggested {
        didSet { if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: "typingShortcut") } }
    }
    @Published var shortcutRecording = false
    @Published var shortcutStatus = ""
    @Published var summaries: [SecretSummary] = []
    @Published var selectedSecret: UUID?
    @Published var message = ""
    @Published var busy = false
    @Published var error: String?
    @Published var sessionLocked = false
    @Published var agentStatus = "Агент запускается…"
    @Published var launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") == nil || UserDefaults.standard.bool(forKey: "launchAtLogin") {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    let store = Store()
    private var loadedRecord: UUID?
    private var signing = false
    var record: Registration? { records.first { $0.id == selectedKey } }
    var connected: Bool { guard !sessionLocked, let record else { return false }; return (try? store.resolve(record, volumes: volumes)) != nil }
    var vaultLoaded: Bool { loadedRecord == record?.id && loadedRecord != nil && connected }
    var selectedSummary: SecretSummary? { summaries.first { $0.id == selectedSecret } }
    var typingRecord: Registration? {
        guard !sessionLocked else { return nil }
        let available = records.filter { (try? store.resolve($0, volumes: volumes)) != nil }
        if let chosen = available.first(where: { $0.id == selectedKey }) { return chosen }
        return available.count == 1 ? available.first : nil
    }
    var ejectableVolume: Volume? {
        VolumeSelection.forEjection(preferred: typingRecord?.binding, available: volumes)
    }
    func ejectVolume() async {
        guard !busy, !signing, let chosen = ejectableVolume else { return }
        busy = true; defer { busy = false }
        do {
            guard let current = Volumes.list().first(where: { $0.url == chosen.url && $0.binding == chosen.binding }) else { throw KeyError("Носитель отключён или изменился.") }
            let url = current.url
            try await Task.detached(priority: .userInitiated) {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            }.value
            refresh()
            typingMessage = "Флешка «\(chosen.name)» безопасно извлечена."
            typingFailed = false
        } catch {
            typingMessage = "Не удалось извлечь флешку: " + error.localizedDescription
            typingFailed = true
        }
    }
    var typingSummary: SecretSummary? { summaries.first { $0.id == typingEntryID } }
    var socketPath: String { store.root.appendingPathComponent("agent.sock").path }
    var sshExample: String { "ssh -o IdentityAgent=\"\(socketPath)\" user@server" }

    func refresh() {
        let permissions = InputPermissionSnapshot(posting: KeyboardTyper.permitted, accessibility: KeyboardTyper.accessibilityTrusted)
        permissionTracker.observe(permissions)
        updateRestartSuggestion()
        if accessibilityPermission != KeyboardTyper.accessibilityTrusted { accessibilityPermission = KeyboardTyper.accessibilityTrusted }
        if keyboardPermission != KeyboardTyper.permitted { keyboardPermission = KeyboardTyper.permitted }
        let freshVolumes = Volumes.list()
        if volumes != freshVolumes { volumes = freshVolumes }
        if !volumes.contains(where: { $0.id == selectedVolume }) { selectedVolume = volumes.first?.id ?? "" }
        do {
            let freshRecords = try store.registrations()
            if records != freshRecords { records = freshRecords }
            if selectedKey == nil { selectedKey = records.first(where: { rec in volumes.contains { $0.binding == rec.binding } })?.id ?? records.first?.id }
        } catch { self.error = error.localizedDescription }
        if (!connected || loadedRecord != selectedKey) && (!summaries.isEmpty || selectedSecret != nil || loadedRecord != nil) { summaries = []; selectedSecret = nil; loadedRecord = nil; typingEntryID = nil }
    }
    private func updateRestartSuggestion() {
        if permissionRestartSuggested != permissionTracker.needsRestart { permissionRestartSuggested = permissionTracker.needsRestart }
    }
    func openKeyboardPermissions() {
        permissionTracker.beginSettingsVisit()
        KeyboardTyper.requestPermission()
    }
    func noteActivatedApplication(_ bundleID: String?) {
        if bundleID == "com.apple.systempreferences" { permissionTracker.settingsActivated() }
        else if bundleID == Bundle.main.bundleIdentifier { returnedFromKeyboardPermissions() }
    }
    func returnedFromKeyboardPermissions() {
        permissionTracker.returnedToApp()
        updateRestartSuggestion()
    }
    func dismissPermissionRestart() { permissionTracker.acknowledge(); updateRestartSuggestion() }
    func lockSession() { sessionLocked = true; summaries = []; selectedSecret = nil; loadedRecord = nil; typingEntryID = nil }
    private func authenticate(_ reason: String) async throws {
        guard !sessionLocked else { throw KeyError("Разблокируйте сеанс macOS.") }
        let context = LAContext(); context.localizedCancelTitle = "Отмена"
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason), !sessionLocked else { throw KeyError("Доступ отменён или сеанс заблокирован.") }
    }
    private func current(_ record: Registration) throws -> (Volume, SymmetricKey) {
        guard !sessionLocked else { throw KeyError("Сеанс заблокирован.") }
        let (token, volume) = try store.resolve(record, volumes: Volumes.list())
        let key = try Vault.load(record.id)
        _ = try token.unlock(binding: volume.binding, wrappingKey: key)
        return (volume, key)
    }
    private func entries(_ record: Registration) throws -> [SecretEntry] {
        let (volume, key) = try current(record)
        return try store.readSecrets(record: record, volume: volume, key: key)
    }
    func create() {
        guard let volume = volumes.first(where: { $0.id == selectedVolume }) else { return }
        do { let key = try store.create(on: volume); selectedKey = key.id; refresh(); message = "Зашифрованный USB-ключ создан. Теперь добавьте записи." }
        catch { self.error = error.localizedDescription }
    }
    func loadSecrets() async {
        guard let record, !busy else { return }; busy = true; defer { busy = false }
        do {
            try await authenticate("Открыть список записей на USB-ключе")
            let (volume, key) = try current(record)
            let payload = try store.readPayload(record: record, volume: volume, key: key)
            let items = payload.entries
            guard selectedKey == record.id else { return }
            summaries = items.map(SecretSummary.init); loadedRecord = record.id; typingEntryID = payload.typingEntryID
            if !summaries.contains(where: { $0.id == selectedSecret }) { selectedSecret = summaries.first?.id }
            message = "Список открыт. Значения расшифровываются только при использовании."
        } catch { self.error = error.localizedDescription }
    }
    func saveSecret(name: String, kind: SecretKind, value: String, generate: Bool) async -> Bool {
        guard let record, !busy else { return false }; busy = true; defer { busy = false }
        do {
            let text = generate && kind == .sshKey ? "ed25519:" + Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString() : value
            let entry = try SecretEntry(name: name, kind: kind, value: text)
            try await authenticate("Записать секрет на USB-ключ")
            let (volume, key) = try current(record)
            let payload = try store.readPayload(record: record, volume: volume, key: key)
            var all = payload.entries
            all.append(entry)
            try store.writeSecrets(all, record: record, volume: volume, key: key)
            if selectedKey == record.id { summaries = all.map(SecretSummary.init); selectedSecret = entry.id; loadedRecord = record.id; typingEntryID = payload.typingEntryID }
            message = "Запись зашифрована и сохранена на флешке."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setTypingDefault() async {
        guard let record, let summary = selectedSummary, summary.kind != .sshKey, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await authenticate("Назначить запись для ввода с USB-ключа")
            let (volume, key) = try current(record)
            var payload = try store.readPayload(record: record, volume: volume, key: key)
            guard let entry = payload.entries.first(where: { $0.id == summary.id && $0.kind != .sshKey }) else { throw KeyError("Запись не найдена.") }
            _ = try TypingPlan.chunks(entry.value)
            payload.typingEntryID = entry.id
            try store.writePayload(payload, record: record, volume: volume, key: key)
            if selectedKey == record.id { typingEntryID = entry.id }
            message = "«\(entry.name)» привязана к кнопке ввода этой флешки."
        } catch { self.error = error.localizedDescription }
    }
    func typeDefault(into target: TypingTarget?) async -> Bool {
        guard !busy else { return false }
        busy = true; typingMessage = ""; typingFailed = false; defer { busy = false }
        do {
            guard KeyboardTyper.permitted else { throw KeyError(KeyboardTyper.permissionFailure) }
            guard let target else { throw KeyError("Выберите поле в другом приложении и повторите ввод.") }
            guard let record = typingRecord else { throw KeyError("Подключите флешку; если их несколько — выберите активную в настройках.") }
            if confirmEveryTyping { try await authenticate("Ввести привязанное значение с USB-ключа") }
            let (volume, key) = try current(record)
            let payload = try store.readPayload(record: record, volume: volume, key: key)
            guard let id = payload.typingEntryID, let entry = payload.entries.first(where: { $0.id == id && $0.kind != .sshKey }) else {
                throw KeyError("Назначьте запись для ввода в основном приложении.")
            }
            try await KeyboardTyper.type(entry.value, into: target) {
                guard !self.sessionLocked, let token = try? self.store.token(on: volume) else { return false }
                return token.id == record.id && token.binding == record.binding && token.publicKey == record.publicKey
            }
            typingMessage = "Значение введено в выбранное поле."
            return true
        } catch { typingMessage = error.localizedDescription; typingFailed = true; return false }
    }
    func deleteSelected() async {
        guard let record, let summary = selectedSummary, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await authenticate("Удалить «\(summary.name)» с USB-ключа")
            let (volume, key) = try current(record)
            let all = try store.readSecrets(record: record, volume: volume, key: key).filter { $0.id != summary.id }
            try store.writeSecrets(all, record: record, volume: volume, key: key)
            summaries = all.map(SecretSummary.init); selectedSecret = summaries.first?.id; if typingEntryID == summary.id { typingEntryID = nil }; message = "Запись удалена."
        } catch { self.error = error.localizedDescription }
    }
    func copyPublic(_ value: String? = nil) {
        guard let value = value ?? selectedSummary?.publicKey ?? record?.publicKey else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        message = "Открытый ключ скопирован. Для SSH добавьте его в ~/.ssh/authorized_keys на сервере."
    }
    func configure() {
        guard let record else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/usbkey-sign")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { error = "Запустите собранное USBKey.app."; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Подключить репозиторий"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.configure(repository: url, record: record, helper: helper); message = "SSH-подпись Git включена для \(url.lastPathComponent)." }
        catch { self.error = error.localizedDescription }
    }
    struct Identity {
        let record: Registration
        let secretID: UUID?
        let blob: Data
        let name: String
    }
    private func identities() throws -> [Identity] {
        guard !sessionLocked else { return [] }
        let mounted = Volumes.list()
        var result: [Identity] = []
        for record in try store.registrations() {
            guard (try? store.resolve(record, volumes: mounted)) != nil else { continue }
            if let blob = Data(base64Encoded: String(record.publicKey.split(separator: " ").dropFirst().first ?? "")) {
                result.append(Identity(record: record, secretID: nil, blob: blob, name: record.name + " / основной ключ"))
            }
            for item in try entries(record) where item.kind == .sshKey {
                let key = try SecretEntry.privateKey(item.value)
                result.append(Identity(record: record, secretID: item.id, blob: SSHSignature.publicBlob(key), name: record.name + " / " + item.name))
            }
        }
        return Array(result.prefix(100))
    }
    func agentReply(_ packet: Data) async -> Data {
        do {
            if packet.first == 13 {
                guard !signing, !sessionLocked else { return Data([5]) }; signing = true; defer { signing = false }
                var reader = SSHReader(packet); _ = try reader.byte()
                let blob = try reader.field(), data = try reader.field()
                guard try reader.word() == 0, reader.finished else { return Data([5]) }
                let user = try AgentProtocol.authenticationUser(data, publicBlob: blob)
                guard let identity = try identities().first(where: { $0.blob == blob }) else { return Data([5]) }
                let alert = NSAlert(); alert.messageText = "Разрешить SSH-вход?"
                alert.informativeText = "Ключ: \(identity.name)\nПользователь сервера: \(user)\nСервер не удостоверен агентом: проверьте имя и host fingerprint в SSH-клиенте. Закрытый ключ останется внутри USBKey."
                alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Разрешить")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertSecondButtonReturn else { return Data([5]) }
                try await authenticate("Подтвердить использование USB-ключа для SSH")
                // A second device read after both prompts makes unplugging fail closed.
                return AgentProtocol.reply(packet, identities: { [] }, sign: { requested, payload in
                    let (volume, wrapping) = try self.current(identity.record)
                    let key: Curve25519.Signing.PrivateKey
                    if let id = identity.secretID {
                        guard let entry = try self.store.readSecrets(record: identity.record, volume: volume, key: wrapping).first(where: { $0.id == id && $0.kind == .sshKey }) else { throw KeyError("SSH-ключ отсутствует.") }
                        key = try SecretEntry.privateKey(entry.value)
                    } else { key = try self.store.token(on: volume).unlock(binding: volume.binding, wrappingKey: wrapping) }
                    guard SSHSignature.publicBlob(key) == requested else { throw KeyError("SSH-ключ изменился.") }
                    return try key.signature(for: payload)
                })
            }
            return AgentProtocol.reply(packet, identities: { try self.identities().map { AgentIdentity(blob: $0.blob, comment: $0.name) } }, sign: { _, _ in throw KeyError("Запрос отклонён.") })
        } catch { return Data([5]) }
    }
}
