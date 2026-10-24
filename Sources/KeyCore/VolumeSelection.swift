import Foundation

public enum VolumeSelection {
    /// Never guess a disk when several are attached. Duplicate bindings are
    /// ambiguous too, even if their human-readable names are different.
    public static func forEjection(preferred: Binding?, available: [Volume]) -> Volume? {
        if let preferred {
            let matches = available.filter { $0.binding == preferred }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return nil }
        }
        return available.count == 1 ? available[0] : nil
    }
}
