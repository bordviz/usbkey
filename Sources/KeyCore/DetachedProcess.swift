import Foundation
import Darwin

public enum DetachedProcess {
    /// Start outside the caller's session/process group before returning. This
    /// prevents launchd from killing the restarter when the old LaunchAgent exits.
    @discardableResult public static func launch(executable: URL, arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        let initialized = posix_spawnattr_init(&attributes)
        guard initialized == 0 else { throw KeyError("Не удалось подготовить перезапуск (\(initialized)).") }
        defer { posix_spawnattr_destroy(&attributes) }
        let configured = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard configured == 0 else { throw KeyError("Не удалось отделить помощник перезапуска (\(configured)).") }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { for item in argv { free(item) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, executable.path, nil, &attributes, buffer.baseAddress!, environ)
        }
        guard result == 0 else { throw KeyError("Не удалось запустить помощник: " + String(cString: strerror(result))) }
        return pid
    }
}
