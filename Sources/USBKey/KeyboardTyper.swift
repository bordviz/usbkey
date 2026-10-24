import AppKit
import ApplicationServices
import KeyCore

/// The destination is an application, not an Accessibility text element.
/// Terminal emulators and canvas/Electron editors often expose no focused AX field.
@MainActor struct TypingTarget {
    let application: NSRunningApplication
    static func capture(fallback: NSRunningApplication? = nil) -> TypingTarget? {
        let front = NSWorkspace.shared.frontmostApplication
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pid = TypingDestination.choose(frontmostPID: front?.processIdentifier,
                                           previousPID: fallback?.isTerminated == false ? fallback?.processIdentifier : nil,
                                           ownPID: ownPID)
        guard let pid, let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return nil }
        return Self(application: application)
    }
    func isActive() -> Bool {
        !application.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }
}
@MainActor enum KeyboardTyper {
    // Posting keyboard events is a distinct capability. AX trust is diagnostic
    // information, not a prerequisite for calling the Quartz posting API.
    static var permitted: Bool { CGPreflightPostEventAccess() }
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    static var permissionFailure: String {
        "macOS не подтверждает отправку клавиатуры для этой копии USBKey. Откройте «Настроить» → «Устройство»: там показаны путь приложения и инструкция восстановления разрешения."
    }
    static func requestPermission() {
        if !permitted { _ = CGRequestPostEventAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    static func type(_ value: String, into target: TypingTarget, devicePresent: () -> Bool) async throws {
        guard permitted else { throw KeyError(permissionFailure) }
        guard !target.application.isTerminated else { throw KeyError("Приложение для ввода закрыто.") }
        let chunks = try TypingPlan.chunks(value)
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: target.application) }
        if NSApp.isActive { NSApp.deactivate() }
        _ = target.application.activate(options: [.activateIgnoringOtherApps])
        // A hotkey can fire before its modifiers are released. Wait for release
        // instead of aborting an otherwise valid request without Touch ID.
        for _ in 0..<60 {
            try Task.checkCancellation()
            if target.isActive() && modifiersReleased { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard target.isActive() else { throw KeyError("Не удалось вернуть фокус приложению. Повторите ввод из нужного приложения.") }
        guard modifiersReleased else { throw KeyError("Отпустите клавиши комбинации и повторите ввод.") }
        // Let the previous app regain keyboard focus after the nonactivating panel closes.
        try await Task.sleep(nanoseconds: 80_000_000)
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw KeyError("Не удалось создать источник клавиатуры.") }
        try await TypingRunner.run(chunks: chunks, isAllowed: {
            permitted && devicePresent() && target.isActive() && modifiersReleased
        }, emit: { units in
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw KeyError("Не удалось создать событие клавиатуры.") }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.flags = []; up.flags = []
            // Deliver real key-down/key-up pairs to the original application.
            // Its own responder/terminal decides where to insert the characters.
            down.postToPid(target.application.processIdentifier)
            up.postToPid(target.application.processIdentifier)
        })
    }
    private static var modifiersReleased: Bool {
        CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }
}
