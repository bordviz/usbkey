import Foundation

public enum TypingPlan {
    /// One Unicode scalar per key-down/key-up pair. Terminal emulators may ignore
    /// all but the first character of a multi-character Quartz keyboard event.
    public static func chunks(_ value: String) throws -> [[UInt16]] {
        guard !value.isEmpty, value.utf8.count <= 65_536 else { throw KeyError("Недопустимая длина значения для ввода.") }
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }) else {
            throw KeyError("Для клавиатурного ввода выберите однострочное значение без Enter, Tab и управляющих символов.")
        }
        return value.unicodeScalars.map { Array(String($0).utf16) }
    }
}

public struct Shortcut: Codable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) throws {
        let allowed: UInt32 = 256 | 512 | 2048 | 4096
        guard keyCode <= 127, modifiers & ~allowed == 0, modifiers & (256 | 2048 | 4096) != 0, !label.isEmpty else {
            throw KeyError("Добавьте ⌘, ⌥ или ⌃ к комбинации клавиш.")
        }
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public static var suggested: Shortcut { try! Shortcut(keyCode: 40, modifiers: 256 | 2048, label: "⌥⌘K") }
}

@MainActor public enum TypingRunner {
    /// Check the destination and device immediately before every emitted chunk.
    public static func run(chunks: [[UInt16]], isAllowed: () -> Bool, emit: ([UInt16]) throws -> Void,
                           wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 12_000_000) }) async throws {
        for units in chunks {
            try Task.checkCancellation()
            guard isAllowed() else { throw KeyError("Ввод остановлен: сменилось приложение, отключена флешка или нажата клавиша-модификатор.") }
            try emit(units)
            try await wait()
        }
    }
}


public enum TypingDestination {
    /// Prefer the currently active external app; use the previous one only when
    /// the menu bar has made USBKey itself frontmost (or no app is reported).
    public static func choose(frontmostPID: Int32?, previousPID: Int32?, ownPID: Int32) -> Int32? {
        if let pid = frontmostPID, pid > 0, pid != ownPID { return pid }
        if let pid = previousPID, pid > 0, pid != ownPID { return pid }
        return nil
    }
}
