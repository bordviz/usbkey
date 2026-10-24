import Foundation

public struct InputPermissionSnapshot: Equatable {
    public let posting: Bool
    public let accessibility: Bool
    public init(posting: Bool, accessibility: Bool) { self.posting = posting; self.accessibility = accessibility }
}

/// TCC may cache the old status until the process restarts. In addition to actual
/// status transitions, offer a restart after returning from our permissions link.
public struct PermissionRestartTracker {
    private var snapshot: InputPermissionSnapshot
    private var settingsRequested = false
    private var settingsSeen = false
    public private(set) var needsRestart = false
    public init(initial: InputPermissionSnapshot) { snapshot = initial }
    public mutating func observe(_ current: InputPermissionSnapshot) {
        if current != snapshot { needsRestart = true; snapshot = current }
    }
    public mutating func beginSettingsVisit() { settingsRequested = true; settingsSeen = false }
    public mutating func settingsActivated() { if settingsRequested { settingsSeen = true } }
    public mutating func returnedToApp() {
        if settingsRequested && settingsSeen {
            needsRestart = true; settingsRequested = false; settingsSeen = false
        }
    }
    public mutating func acknowledge() { needsRestart = false }
}
