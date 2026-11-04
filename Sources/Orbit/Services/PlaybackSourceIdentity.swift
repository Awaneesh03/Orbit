/// How Orbit presents each playback source, in one place: its name, the app
/// whose icon stands in for missing artwork, the artwork's shape and the
/// source label. A new source (Spotify, later) is one more entry in `all`.
struct PlaybackSourceIdentity: Equatable, Sendable {
    enum ArtworkShape: Equatable, Sendable { case square, widescreen }

    let sourceID: String
    /// The source as a whole ("Music", "YouTube in Brave").
    let displayName: String
    /// The app whose icon stands in for artwork; read from disk, never
    /// launched. Empty when there's no app (the fallback symbol is used).
    let bundleIdentifier: String
    /// When the app's icon can't be read (or there's no app).
    let fallbackSymbol: String
    /// Added after the item's own app name in labels: "YOUTUBE · BRAVE".
    let host: String?
    let artworkShape: ArtworkShape
    /// Items of this source whose artwork has another shape, by app name
    /// (YouTube Music's square covers in Brave).
    let artworkShapeByApp: [String: ArtworkShape]

    func artworkShape(for item: NowPlaying) -> ArtworkShape { artworkShapeByApp[item.appName] ?? artworkShape }

    /// "Music", "YouTube · Brave", "YouTube Music · Brave".
    func label(for item: NowPlaying) -> String { [item.appName, host].compactMap { $0 }.joined(separator: " · ") }

    static let appleMusic = PlaybackSourceIdentity(
        sourceID: "apple-music", displayName: "Music", bundleIdentifier: "com.apple.Music", fallbackSymbol: "music.note",
        host: nil, artworkShape: .square, artworkShapeByApp: [:])

    static let braveYouTube = PlaybackSourceIdentity(
        sourceID: "brave-youtube", displayName: "YouTube in Brave", bundleIdentifier: "com.brave.Browser",
        fallbackSymbol: "play.rectangle", host: "Brave", artworkShape: .widescreen,
        artworkShapeByApp: ["YouTube Music": .square])

    static let all = [appleMusic, braveYouTube]

    /// The identity for a source id; an unknown source gets a neutral one.
    static func of(_ sourceID: String) -> PlaybackSourceIdentity {
        all.first { $0.sourceID == sourceID }
            ?? PlaybackSourceIdentity(sourceID: sourceID, displayName: sourceID, bundleIdentifier: "",
                                      fallbackSymbol: "music.note", host: nil, artworkShape: .square, artworkShapeByApp: [:])
    }
}
