import Foundation

enum Relaunch {
    /// Spawns a shell that waits for `pid` to end and then opens `bundle` without its window. It runs in a session
    /// of its own: left in the app's process group it would die with the app when launchd ends the group of a
    /// login-item job or of the job the Dock opened the app in. Every descriptor, stdio included, is closed in it.
    static func afterExit(of pid: pid_t, open bundle: URL) throws {
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$1\" --args --tray"
        let arguments = ["/bin/sh", "-c", script, "sh", bundle.path]
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var child: pid_t = 0
        let result = posix_spawn(&child, "/bin/sh", nil, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
    }
}
