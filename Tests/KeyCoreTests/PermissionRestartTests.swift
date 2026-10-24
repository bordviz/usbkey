import XCTest
import Darwin
@testable import KeyCore

final class PermissionRestartTests: XCTestCase {
    let denied = InputPermissionSnapshot(posting: false, accessibility: false)
    let allowed = InputPermissionSnapshot(posting: true, accessibility: true)
    func testStartupAndUnchangedPollingDoNotPrompt() {
        var tracker = PermissionRestartTracker(initial: allowed)
        tracker.observe(allowed); tracker.observe(allowed)
        XCTAssertFalse(tracker.needsRestart)
        tracker.returnedToApp()
        XCTAssertFalse(tracker.needsRestart)
    }
    func testGrantAndRevocationBothSuggestRestartWithoutRepeatedPrompt() {
        var tracker = PermissionRestartTracker(initial: denied)
        tracker.observe(allowed); XCTAssertTrue(tracker.needsRestart)
        tracker.acknowledge(); tracker.observe(allowed)
        XCTAssertFalse(tracker.needsRestart)
        tracker.observe(denied); XCTAssertTrue(tracker.needsRestart)
    }
    func testReturnFromSettingsSuggestsRestartEvenForCachedStatus() {
        var tracker = PermissionRestartTracker(initial: denied)
        tracker.beginSettingsVisit(); tracker.returnedToApp()
        XCTAssertFalse(tracker.needsRestart)
        tracker.settingsActivated(); tracker.observe(denied); tracker.returnedToApp()
        XCTAssertTrue(tracker.needsRestart)
        tracker.acknowledge(); tracker.returnedToApp()
        XCTAssertFalse(tracker.needsRestart)
    }
    func testUnrelatedSettingsVisitsDoNotPrompt() {
        var tracker = PermissionRestartTracker(initial: allowed)
        tracker.settingsActivated(); tracker.returnedToApp()
        XCTAssertFalse(tracker.needsRestart)
    }
    func testDetachedProcessSurvivesIndependentOfParentProcessGroup() throws {
        let pid = try DetachedProcess.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.3"])
        XCTAssertEqual(getsid(pid), pid)
        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertNotEqual(getpgid(pid), getpgrp())
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertEqual(status, 0)
    }
    func testMissingRelaunchExecutableFailsBeforeClosingTheApp() {
        XCTAssertThrowsError(try DetachedProcess.launch(executable: URL(fileURLWithPath: "/nonexistent/USBKeyLifecycle"), arguments: []))
    }
}
