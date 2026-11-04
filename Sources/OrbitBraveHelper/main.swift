import Darwin
import Foundation
import OrbitBridge

// Orbit's Brave native messaging host. Brave starts it when Orbit's extension
// connects (see BraveExtension/ and scripts/install-brave-helper.sh) and
// closes stdin when the extension lets go, which ends it.

let extensionOrigin = "chrome-extension://iejmobaapejgfmjnecdgnmclnkpilpaf/"

signal(SIGPIPE, SIG_IGN)
// Diagnostics go to the unified log or stderr, never stdout (the protocol).
// Brave passes the caller's origin as an argument; it must be exactly ours.
let arguments = CommandLine.arguments.dropFirst()
guard isatty(STDIN_FILENO) == 0, arguments.contains(extensionOrigin) else {
    bridgeLog.error("refused to start: arguments \(arguments.joined(separator: " "), privacy: .public)")
    FileHandle.standardError.write(Data("OrbitBraveHelper is started by Brave for Orbit's extension, not by hand.\n".utf8))
    exit(64)
}
bridgeLog.notice("launched by Brave for Orbit's extension")

let host = NativeHost(onExit: { exit($0) })
host.start()
dispatchMain()
