import AppKit

// Ignore SIGPIPE process-wide. Writing to a pipe/socket whose read end has
// closed (e.g. a native-messaging host process that exited) otherwise raises
// SIGPIPE, whose default disposition terminates the app ("signal 13"). With
// SIG_IGN the failing write returns EPIPE instead, which callers handle.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
