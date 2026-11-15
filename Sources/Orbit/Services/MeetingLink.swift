import AppKit

// Join links for calendar events (Milestone 15). Read locally from the event's
// URL, location and notes; nothing is sent anywhere, and a link opens only
// when the user clicks Join (in the default browser, or the meeting app that
// claims the link). Event text is only ever searched for a URL: never run.

enum MeetingLink {
    /// Video services whose links are trusted in free text (location, notes).
    static let knownHosts = ["meet.google.com", "zoom.us", "zoomgov.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                             "whereby.com", "gotomeeting.com", "meet.goto.com", "app.chime.aws", "meet.jit.si", "join.skype.com"]
    static let maxLength = 2048

    /// The event's own URL field may be any plain https link; free text only a known video service.
    static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, let valid = validate(url, requireKnownHost: false) { return valid }
        for text in [location, notes].compactMap({ $0 }) {
            for candidate in links(in: text) {
                if let valid = validate(candidate, requireKnownHost: true) { return valid }
            }
        }
        return nil
    }

    /// https only, a real host name, no credentials, a standard port, a sane length.
    static func validate(_ url: URL, requireKnownHost: Bool) -> URL? {
        guard url.absoluteString.count <= maxLength,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443
        else { return nil }
        if requireKnownHost, service(host) == nil { return nil }
        return url
    }

    /// "Google Meet", "Zoom"…: nil for an unknown host.
    static func service(_ host: String) -> String? {
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("meet.google.com") { return "Google Meet" }
        if matches("zoom.us") || matches("zoomgov.com") { return "Zoom" }
        if matches("teams.microsoft.com") || matches("teams.live.com") { return "Microsoft Teams" }
        if matches("webex.com") { return "Webex" }
        if matches("whereby.com") { return "Whereby" }
        if matches("gotomeeting.com") || matches("meet.goto.com") { return "GoTo Meeting" }
        if matches("app.chime.aws") { return "Amazon Chime" }
        if matches("meet.jit.si") { return "Jitsi Meet" }
        if matches("join.skype.com") { return "Skype" }
        return nil
    }

    static func service(of url: URL) -> String? { url.host().flatMap { service($0.lowercased()) } }

    /// URLs in free text (the system's link detector; local, nothing fetched).
    static func links(in text: String) -> [URL] {
        guard text.count <= 20_000, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }

    /// Opens a validated link: the default browser, or the meeting app registered for it. Only on a click.
    @MainActor @discardableResult
    static func open(_ url: URL) -> Bool {
        guard validate(url, requireKnownHost: false) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }
}
