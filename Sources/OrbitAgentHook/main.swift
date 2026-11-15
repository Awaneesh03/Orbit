import Darwin
import Foundation
import OrbitBridge

// Orbit's AI Hub hook helper (docs/AI_HUB_SPEC.md §6, §14): an agent's hook
// runs `OrbitAgentHook --agent <id> --event <name>` with the event's JSON on
// stdin. All the work is in AgentHookClient. Not installed anywhere yet
// (Phase 2 decides that).

signal(SIGPIPE, SIG_IGN)
let environment = ProcessInfo.processInfo.environment
// Always Orbit's own socket: no environment override, so an agent's (or a project's)
// environment can't send hook payloads anywhere else.
let socketPath = UnixSocket.agentsPath
exit(AgentHookClient.main(
    arguments: Array(CommandLine.arguments.dropFirst()), input: STDIN_FILENO, stdinIsTerminal: isatty(STDIN_FILENO) != 0,
    environment: environment, parentPID: getppid(), socketPath: socketPath,
    writeError: { fputs($0, stderr) },  // fputs: FileHandle.write raises on a closed stderr
    writeOutput: { data in data.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, data.count, stdout) }; fflush(stdout) }))
