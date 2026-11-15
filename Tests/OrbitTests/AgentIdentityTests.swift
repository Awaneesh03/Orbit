import AppKit
import Testing
@testable import Orbit

// Milestone 5: agent identity. No initials: the vendor's installed app icon,
// or an original glyph. Nothing trademarked is bundled.

@MainActor @Test func everyKnownAgentHasItsOwnGlyphAndColour() throws {
    let ids = AgentDiscovery.known.map(\.id)
    let agents = try ids.map { try #require(AgentID($0)) }
    let glyphs = agents.map(AgentStyle.glyph)
    #expect(Set(glyphs).count == agents.count)  // distinct
    #expect(glyphs.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })  // real symbols
    #expect(AgentStyle.glyph(try #require(AgentID("some-new-agent"))) == "cpu")
    #expect(AgentStyle.glyph(try #require(AgentID("demo-alpha"))) == "theatermasks")
}

@MainActor @Test func vendorIconsComeFromInstalledAppsOnly() throws {
    defer { AgentIcons.reset(); AgentIcons.locate = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }
    var asked: [String] = []
    AgentIcons.reset()
    AgentIcons.locate = { id in
        asked.append(id)
        return id == "com.openai.chat" ? URL(filePath: "/System/Applications/Calculator.app") : nil
    }
    let codex = try #require(AgentID("codex"))
    #expect(AgentIcons.icon(for: codex) != nil)  // the second candidate is installed
    #expect(asked == ["com.openai.codex", "com.openai.chat"], "\(asked)")
    _ = AgentIcons.icon(for: codex)
    #expect(asked.count == 2)  // cached
    let opencode = try #require(AgentID("opencode"))
    #expect(AgentIcons.icon(for: opencode) == nil && AgentStyle.vendorApps(opencode).isEmpty)  // a CLI: the glyph
    let claude = try #require(AgentID("claude-code"))
    #expect(AgentIcons.icon(for: claude) == nil)  // not installed (in this fake): glyph, never a guess
    _ = AgentIcons.icon(for: claude)
    #expect(asked.filter { $0 == "com.anthropic.claudefordesktop" }.count == 1)  // a miss is remembered
}

@Test func antigravityIDEIsDiscovered() {
    let found = AgentDiscovery.scan(home: URL(filePath: "/Users/nobody"), exists: { $0 == "/Applications/Antigravity IDE.app" })
    #expect(found.first { $0.id == "antigravity" }?.isInstalled == true)
}
