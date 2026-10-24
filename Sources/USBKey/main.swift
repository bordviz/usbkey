import SwiftUI
import Combine
import AppKit
import CryptoKit
import KeyCore
import Darwin

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data(("USBKey: " + error.localizedDescription + "\n").utf8)); exit(1)
}

func gitSSH(_ arguments: [String]) throws {
    guard arguments.contains("sign") else {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); p.arguments = arguments
        p.standardInput = FileHandle.standardInput; p.standardOutput = FileHandle.standardOutput; p.standardError = FileHandle.standardError
        try p.run(); p.waitUntilExit(); exit(p.terminationStatus)
    }
    guard arguments.count == 7, Array(arguments.prefix(5)) == ["-Y", "sign", "-n", "git", "-f"] else {
        throw KeyError("Поддерживается только SSH-подпись Git.")
    }
    let store = Store()
    let requested = URL(fileURLWithPath: arguments[5]).standardizedFileURL
    guard let record = try store.registrations().first(where: { store.publicURL($0.id).standardizedFileURL == requested }) else {
        throw KeyError("Открытый ключ не зарегистрирован в USBKey.")
    }
    _ = try store.resolve(record, volumes: Volumes.list())
    let source = URL(fileURLWithPath: arguments[6])
    let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1024 * 1024 else {
        throw KeyError("Недопустимые данные для подписи.")
    }
    let message = try Data(contentsOf: source)
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
    let alert = NSAlert(); alert.messageText = "Подписать Git-объект?"
    alert.informativeText = "Флешка: \(record.name)\nКаталог: \(FileManager.default.currentDirectoryPath)\nКлюч: \(SSHSignature.fingerprint(record.publicKey))\nПроверьте автора, сообщение и tree ниже. Подпись не проверяет содержимое diff."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 610, height: 260))
    scroll.hasVerticalScroller = true
    let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    text.string = String(decoding: message.prefix(65536), as: UTF8.self) + (message.count > 65536 ? "\n[Предпросмотр обрезан]" : "")
    scroll.documentView = text; alert.accessoryView = scroll
    alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Подписать")
    guard alert.runModal() == .alertSecondButtonReturn else { throw KeyError("Подпись отменена.") }
    let (token, volume) = try store.resolve(record, volumes: Volumes.list())
    let key = try token.unlock(binding: volume.binding, wrappingKey: Vault.load(record.id))
    let signature = try SSHSignature.sign(message, key: key)
    try signature.write(to: URL(fileURLWithPath: source.path + ".sig"), options: [.withoutOverwriting])
}

// Git keeps its own process; the resident UI hosts the SSH agent and menu bar.
if CommandLine.arguments.dropFirst().first == "--git-ssh" {
    do { try gitSSH(Array(CommandLine.arguments.dropFirst(2))) } catch { fail(error) }
} else {
    let background = CommandLine.arguments.contains("--background")
    if background && !CommandLine.arguments.contains("--relaunch") && !CommandLine.arguments.contains("--updated") && UserDefaults.standard.object(forKey: "launchAtLogin") != nil && !UserDefaults.standard.bool(forKey: "launchAtLogin") { exit(0) }
    if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.usbkey.app").first(where: { $0.processIdentifier != getpid() }) {
        if !background { existing.activate(options: [.activateAllWindows]) }
        exit(0)
    }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppController(background: background)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
