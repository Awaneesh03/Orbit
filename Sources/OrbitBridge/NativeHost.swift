import Darwin
import Foundation
import os

/// The helper's diagnostics, in the unified log (`log stream --predicate
/// 'subsystem == "com.awaneeshgupta.orbit"'`), never on stdout, which carries
/// the native messaging protocol. Lifecycle and counts only: never titles.
package let bridgeLog = Logger(subsystem: "com.awaneeshgupta.orbit", category: "brave-helper")

/// The helper Brave starts for Orbit's extension: native messages on
/// stdin/stdout, Orbit on the local socket. It keeps only the latest state of
/// each open YouTube tab, in memory, to tell Orbit again after a reconnect,
/// and exits when Brave closes stdin.
@MainActor
package final class NativeHost {
    private let input: Int32
    private let output: Int32
    private let socketPath: String
    private let retryInterval: DispatchTimeInterval
    private let onExit: (Int32) -> Void
    private var inputDecoder = FrameDecoder()
    private var socketDecoder = FrameDecoder()
    private var inputSource: DispatchSourceRead?
    private var socketSource: DispatchSourceRead?
    private var retryTimer: DispatchSourceTimer?
    private var socket: Int32 = -1
    private var finished = false
    private var browserMessages = 0
    package private(set) var tabs: [Int: TabPlayback] = [:]
    package var isConnected: Bool { socket >= 0 }

    /// Tabs remembered at most; more is not a real browser.
    private static let maxTabs = 64

    package init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, socketPath: String = UnixSocket.defaultPath,
                 retryInterval: DispatchTimeInterval = .seconds(3), onExit: @escaping (Int32) -> Void) {
        self.input = input
        self.output = output
        self.socketPath = socketPath
        self.retryInterval = retryInterval
        self.onExit = onExit
    }

    package func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: input, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readInput() } }
        source.resume()
        inputSource = source
        bridgeLog.notice("helper started; Orbit socket: \(self.socketPath, privacy: .public)")
        connect()
    }

    /// Stops everything once; Brave sees the process exit.
    package func finish(_ code: Int32) {
        guard !finished else { return }
        finished = true
        bridgeLog.notice("helper exiting (\(code, privacy: .public)) after \(self.browserMessages, privacy: .public) message(s) from Brave")
        inputSource?.cancel()
        inputSource = nil
        retryTimer?.cancel()
        retryTimer = nil
        dropSocket()
        onExit(code)
    }

    // MARK: Brave

    private func readInput() {
        guard let chunk = UnixSocket.readChunk(input) else {
            bridgeLog.notice("Brave closed the connection (stdin ended)")
            return finish(0)
        }
        inputDecoder.append(chunk)
        do {
            while let payload = try inputDecoder.next() { fromBrowser(payload) }
        } catch {
            bridgeLog.error("bad frame from Brave (\(String(describing: error), privacy: .public)); exiting")
            finish(1)
        }
    }

    private func fromBrowser(_ payload: Data) {
        let message: BridgeMessage
        do {
            message = try BridgeMessage.decode(payload)
        } catch {
            return bridgeLog.error("ignored an invalid message from Brave: \(error.description, privacy: .public)")
        }
        browserMessages += 1
        if browserMessages == 1 { bridgeLog.notice("first message from Brave received and valid") }
        switch message {
        case .update(let playback):
            guard tabs[playback.tab] != nil || tabs.count < Self.maxTabs else { return }
            tabs[playback.tab] = playback
        case .closed(let tab):
            guard tabs.removeValue(forKey: tab) != nil else { return }
        case .command:
            return  // only Orbit sends commands
        }
        guard isConnected else { return connect() }  // connecting replays every tab
        if !UnixSocket.writeAll(socket, BridgeFraming.frame(message.encoded())) {
            bridgeLog.error("couldn't write to Orbit; reconnecting")
            lostOrbit()
        }
    }

    private func toBrowser(_ command: BridgeCommand) {
        guard tabs[command.tab] != nil else { return }  // only tabs Brave told us about
        bridgeLog.notice("command from Orbit for tab \(command.tab, privacy: .public): \(command.action.rawValue, privacy: .public)")
        if !UnixSocket.writeAll(output, BridgeFraming.frame(BridgeMessage.command(command).encoded())) {
            bridgeLog.error("couldn't write to Brave; exiting")
            finish(0)
        }
    }

    // MARK: Orbit

    private func connect() {
        guard !isConnected, !finished else { return }
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath)
        } catch {
            if retryTimer == nil { bridgeLog.notice("Orbit isn't reachable (\(error.description, privacy: .public)); retrying") }
            return scheduleRetry()
        }
        bridgeLog.notice("connected to Orbit; sending \(self.tabs.count, privacy: .public) tab(s)")
        retryTimer?.cancel()
        retryTimer = nil
        socket = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readSocket() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        socketSource = source
        for tab in tabs.keys.sorted() {
            guard let playback = tabs[tab], UnixSocket.writeAll(fd, BridgeFraming.frame(BridgeMessage.update(playback).encoded())) else {
                return lostOrbit()
            }
        }
    }

    private func readSocket() {
        guard isConnected else { return }
        guard let chunk = UnixSocket.readChunk(socket) else {
            bridgeLog.notice("Orbit closed the socket")
            return lostOrbit()
        }
        socketDecoder.append(chunk)
        do {
            while let payload = try socketDecoder.next() {
                if case .command(let command)? = try? BridgeMessage.decode(payload) { toBrowser(command) }
                guard isConnected else { return }
            }
        } catch {
            bridgeLog.error("bad frame from Orbit; reconnecting")
            lostOrbit()
        }
    }

    private func lostOrbit() {
        dropSocket()
        scheduleRetry()
    }

    private func dropSocket() {
        socketSource?.cancel()  // closes the socket
        socketSource = nil
        socket = -1
        socketDecoder = FrameDecoder()
    }

    /// While Orbit isn't running: try again every few seconds (a single
    /// connect call), for as long as Brave keeps the helper open.
    private func scheduleRetry() {
        guard retryTimer == nil, !finished else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.connect() } }
        timer.resume()
        retryTimer = timer
    }
}
