import Foundation

// What the Brave extension, the native messaging helper and Orbit say to each
// other. Every message is validated twice: by the helper (its input comes from
// web pages via the extension) and again by Orbit (its socket is local, but
// the bytes are still untrusted). Nothing here is ever written to disk.

/// Chrome native messaging framing, also used on Orbit's socket: a 32-bit
/// length in native byte order (little-endian on every Mac) followed by UTF-8 JSON.
package enum BridgeFraming {
    /// Orbit's own limit, far above any real message (Chrome allows 64 MiB).
    package static let maxMessageBytes = 64 * 1024

    package static func frame(_ payload: Data) -> Data {
        precondition(!payload.isEmpty && payload.count <= maxMessageBytes)
        var length = UInt32(payload.count).littleEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

/// Splits a byte stream into payloads. A bad length is fatal: the stream
/// can't be resynchronised, so the connection must be closed.
package struct FrameDecoder {
    package enum Failure: Error, Equatable {
        case empty
        case tooLarge(Int)
    }

    private var buffer = Data()

    package init() {}

    package mutating func append(_ bytes: Data) { buffer.append(bytes) }

    /// The next complete payload, or nil until more bytes arrive.
    package mutating func next() throws(Failure) -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = Int(UInt32(littleEndian: buffer[start ..< start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length > 0 else { throw .empty }
        guard length <= BridgeFraming.maxMessageBytes else { throw .tooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let payload = Data(buffer[start + 4 ..< start + 4 + length])
        buffer = Data(buffer[(start + 4 + length)...])
        return payload
    }
}

// MARK: Messages

package enum YouTubeSite: String, Codable, Sendable {
    case youtube, music
}

package enum VideoState: String, Codable, Sendable {
    case playing, paused, ended
}

/// One tab's main YouTube player, as the extension reports it.
package struct TabPlayback: Codable, Equatable, Sendable {
    package var tab: Int
    package var site: YouTubeSite
    package var state: VideoState
    /// Brave says this tab is making sound.
    package var audible: Bool
    package var muted: Bool
    package var ad: Bool
    package var videoID: String?
    package var title: String?
    package var channel: String?
    package var album: String?
    package var artwork: String?
    /// Seconds, as of `at`.
    package var position: Double
    /// Seconds; nil for live streams and before the video has loaded.
    package var duration: Double?
    /// Effective rate: 0 while paused or buffering.
    package var rate: Double
    /// When `position` was read, in milliseconds since 1970.
    package var at: Double

    package init(tab: Int, site: YouTubeSite = .youtube, state: VideoState, audible: Bool = false, muted: Bool = false,
                 ad: Bool = false, videoID: String? = nil, title: String? = nil, channel: String? = nil,
                 album: String? = nil, artwork: String? = nil, position: Double = 0, duration: Double? = nil,
                 rate: Double = 0, at: Double) {
        self.tab = tab
        self.site = site
        self.state = state
        self.audible = audible
        self.muted = muted
        self.ad = ad
        self.videoID = videoID
        self.title = title
        self.channel = channel
        self.album = album
        self.artwork = artwork
        self.position = position
        self.duration = duration
        self.rate = rate
        self.at = at
    }
}

/// Orbit asking the extension to act on one tab's player.
package struct BridgeCommand: Codable, Equatable, Sendable {
    package enum Action: String, Codable, Sendable {
        case play, pause, seek
    }

    package var tab: Int
    /// The video the command was meant for: a tab that has moved on ignores it.
    package var videoID: String?
    package var action: Action
    package var position: Double?

    package init(tab: Int, videoID: String?, action: Action, position: Double? = nil) {
        self.tab = tab
        self.videoID = videoID
        self.action = action
        self.position = position
    }
}

package enum BridgeMessage: Equatable, Sendable {
    /// Browser → Orbit: a tab's player changed.
    case update(TabPlayback)
    /// Browser → Orbit: the tab closed or left YouTube.
    case closed(tab: Int)
    /// Orbit → browser.
    case command(BridgeCommand)
}

package struct BridgeError: Error, Equatable, CustomStringConvertible {
    package let description: String
    init(_ description: String) { self.description = description }
}

extension BridgeMessage {
    private struct Envelope: Decodable {
        let type: String
        let tab: Int?
    }

    private static let maxSeconds = 10_000_000.0  // ~115 days: anything longer is garbage

    /// Decodes and validates one payload. Text is trimmed and capped, an
    /// artwork URL outside YouTube's image hosts is dropped, and impossible
    /// numbers reject the whole message.
    package static func decode(_ payload: Data) throws(BridgeError) -> BridgeMessage {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: payload) else { throw BridgeError("not a message") }
        switch envelope.type {
        case "update":
            guard let playback = try? decoder.decode(TabPlayback.self, from: payload) else { throw BridgeError("bad update") }
            return .update(try validated(playback))
        case "closed":
            guard let tab = envelope.tab else { throw BridgeError("bad closed") }
            return .closed(tab: try validatedTab(tab))
        case "command":
            guard let command = try? decoder.decode(BridgeCommand.self, from: payload) else { throw BridgeError("bad command") }
            return .command(try validated(command))
        default:
            throw BridgeError("unknown type")
        }
    }

    package func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func with<T: Encodable>(_ type: String, _ value: T) -> Data {
            // Flattened: {"type": …, …fields}
            var object = (try? JSONSerialization.jsonObject(with: encoder.encode(value))) as? [String: Any] ?? [:]
            object["type"] = type
            return (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
        }
        return switch self {
        case .update(let playback): with("update", playback)
        case .closed(let tab): with("closed", ["tab": tab])
        case .command(let command): with("command", command)
        }
    }

    private static func validatedTab(_ tab: Int) throws(BridgeError) -> Int {
        guard (0 ... Int(Int32.max)).contains(tab) else { throw BridgeError("bad tab") }
        return tab
    }

    private static func validated(_ input: TabPlayback) throws(BridgeError) -> TabPlayback {
        var playback = input
        playback.tab = try validatedTab(input.tab)
        guard input.position.isFinite, (0 ... maxSeconds).contains(input.position) else { throw BridgeError("bad position") }
        guard input.rate.isFinite, (0 ... 16).contains(input.rate) else { throw BridgeError("bad rate") }
        guard input.at.isFinite, input.at > 0 else { throw BridgeError("bad time") }
        if let duration = input.duration, !(duration.isFinite && duration > 0 && duration <= maxSeconds) { playback.duration = nil }
        playback.title = text(input.title, limit: 300)
        playback.channel = text(input.channel, limit: 200)
        playback.album = text(input.album, limit: 200)
        playback.videoID = videoID(input.videoID)
        playback.artwork = artworkURL(input.artwork)?.absoluteString
        return playback
    }

    private static func validated(_ input: BridgeCommand) throws(BridgeError) -> BridgeCommand {
        var command = input
        command.tab = try validatedTab(input.tab)
        command.videoID = videoID(input.videoID)
        if input.action == .seek {
            guard let position = input.position, position.isFinite, (0 ... maxSeconds).contains(position) else {
                throw BridgeError("bad seek")
            }
        } else {
            command.position = nil
        }
        return command
    }

    /// Trimmed, without control characters, capped; nil when nothing is left.
    private static func text(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }

    private static func videoID(_ value: String?) -> String? {
        guard let value, (1 ... 32).contains(value.count),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return value
    }

    /// Thumbnails only from YouTube's own image hosts, over HTTPS.
    package static func artworkURL(_ value: String?) -> URL? {
        guard let value, value.count <= 2048, let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil, let host = url.host()?.lowercased() else { return nil }
        let allowed = ["ytimg.com", "ggpht.com", "googleusercontent.com"]
        return allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }) ? url : nil
    }
}
