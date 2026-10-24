import AppKit
import Foundation
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--relaunch" {
    guard args.count == 4, let oldPID = pid_t(args[1]), oldPID > 1,
          args[2].hasPrefix("/"), args[2].hasSuffix(".app"), ["foreground", "background"].contains(args[3]) else { exit(2) }
    // Leave the old LaunchAgent's process group before it exits. launchd must
    // not terminate this restarter together with the original UI process.
    if getsid(0) != getpid() { guard setsid() >= 0 else { exit(3) } }
    let deadline = Date().addingTimeInterval(10)
    while kill(oldPID, 0) == 0 {
        guard Date() < deadline else { exit(4) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = args[3] == "foreground" ? ["-n", args[2], "--args", "--relaunch"] : ["-g", "-n", args[2], "--args", "--background", "--relaunch"]
    open.standardInput = FileHandle.nullDevice; open.standardOutput = FileHandle.nullDevice; open.standardError = FileHandle.nullDevice
    do { try open.run(); open.waitUntilExit(); exit(open.terminationStatus) } catch { exit(5) }
}

guard args.isEmpty || args == ["--list"] else { exit(2) }
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "local.usbkey.app").filter { $0.processIdentifier != getpid() }
if args == ["--list"] {
    for app in applications { print("\(app.processIdentifier) \(app.bundleURL?.path ?? "USBKey")") }
    exit(0)
}
// The installer invokes this helper as the logged-in GUI user, not as root.
for app in applications { _ = app.terminate() }
let deadline = Date().addingTimeInterval(5)
while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
for app in applications where !app.isTerminated { _ = app.forceTerminate() }
let forceDeadline = Date().addingTimeInterval(2)
while applications.contains(where: { !$0.isTerminated }) && Date() < forceDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
exit(applications.contains(where: { !$0.isTerminated }) ? 1 : 0)
