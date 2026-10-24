import AppKit
import SwiftUI
import Carbon
import KeyCore

@MainActor final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x55534B59, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut?) throws {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        guard let shortcut else { return }
        guard handler != nil else { throw KeyError("Не удалось установить обработчик глобальных клавиш.") }
        _ = try Shortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, label: shortcut.label)
        let id = EventHotKeyID(signature: 0x55534B59, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { throw KeyError("Комбинация занята или недоступна (\(status)). Выберите другую.") }
    }
    func stop() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @SwiftUI.Binding var shortcut: Shortcut
    @SwiftUI.Binding var recording: Bool
    var onError: (String) -> Void
    func makeNSView(context: Context) -> RecorderControl { RecorderControl() }
    func updateNSView(_ nsView: RecorderControl, context: Context) {
        nsView.isRecording = recording
        nsView.title = recording ? "Нажмите комбинацию… Esc — отмена" : shortcut.label
        nsView.begin = { recording = true }
        nsView.end = { recording = false }
        nsView.record = { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0, label = ""
            if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
            if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
            if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
            let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
            label += special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            do { shortcut = try Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label) }
            catch { onError(error.localizedDescription) }
            recording = false
        }
    }
}
final class RecorderControl: NSButton {
    var isRecording = false
    var begin: (() -> Void)?
    var end: (() -> Void)?
    var record: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; isBordered = false; font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        contentTintColor = .white; target = self; action = #selector(start)
        setAccessibilityLabel("Комбинация для ввода")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func start() { isRecording = true; begin?(); window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        isRecording = false
        if event.keyCode == 53 { end?(); window?.makeFirstResponder(nil) }
        else { record?(event); window?.makeFirstResponder(nil) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func resignFirstResponder() -> Bool { end?(); return super.resignFirstResponder() }
}
