import Darwin

public enum ProcessSignals {
    /// The host writes to sockets and pipes whose reader can vanish at any
    /// moment: a client that gave up waiting, an exited child, a framework
    /// connection torn down with a panel. At SIGPIPE's default action one such
    /// late write ends the whole resident host; ignored, the write fails with
    /// EPIPE and its call site reports the error.
    ///
    /// Call once at startup, before any socket, pipe or child process exists.
    /// An ignored signal survives exec: Foundation's `Process` restores default
    /// dispositions in its children, but a `posix_spawn` caller must list
    /// SIGPIPE in `POSIX_SPAWN_SETSIGDEF`.
    public static func ignoreBrokenPipes() {
        signal(SIGPIPE, SIG_IGN)
    }
}
