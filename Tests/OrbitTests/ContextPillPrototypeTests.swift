import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 15: three candidate designs for the floating status pill, rendered under a mock
// menu bar on light and dark wallpapers (ORBIT_RENDER=1 → docs/screenshots/m15-pill-prototypes/).
// The chosen design (A) lives in ContextPill.swift; these stay as the record of the comparison.

private struct Sample { let glyph: String; let title: String; let detail: String; let urgent: Bool }
private let samples = [
    Sample(glyph: "calendar", title: "Design review", detail: "in 24 min", urgent: false),
    Sample(glyph: "calendar", title: "Design review", detail: "in 4 min", urgent: true),
    Sample(glyph: "video.fill", title: "Design review", detail: "now", urgent: true),
    Sample(glyph: "hand.raised.fill", title: "Claude Code needs you", detail: "", urgent: true),
]
private let amber = Color(red: 1.0, green: 0.72, blue: 0.30)

private struct PrototypeA: View {  // hardware capsule: glyph disc, title, tinted countdown
    let sample: Sample
    var body: some View {
        let tint = sample.urgent ? amber : Color.white.opacity(0.6)
        HStack(spacing: 8) {
            Image(systemName: sample.glyph).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                .frame(width: 20, height: 20).background(tint.opacity(0.16), in: .circle)
            Text(sample.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.94)).lineLimit(1)
            if !sample.detail.isEmpty {
                Text(sample.detail).font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
            }
        }
        .padding(.leading, 5).padding(.trailing, 12).frame(height: 30)
        .islandSurface(in: Capsule(style: .continuous))
    }
}

private struct PrototypeB: View {  // status dot, one line
    let sample: Sample
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(sample.urgent ? amber : Color.white.opacity(0.45)).frame(width: 7, height: 7)
            Text(sample.detail.isEmpty ? sample.title : "\(sample.title) · \(sample.detail)")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 26)
        .islandSurface(in: Capsule(style: .continuous))
    }
}

private struct PrototypeC: View {  // split chip: tinted countdown first
    let sample: Sample
    var body: some View {
        HStack(spacing: 8) {
            Text(sample.detail.isEmpty ? "!" : sample.detail)
                .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                .padding(.horizontal, 8).frame(height: 22).background(sample.urgent ? amber : Color.white.opacity(0.7), in: .capsule)
            Text(sample.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.leading, 4).padding(.trailing, 12).frame(height: 30)
        .islandSurface(in: Capsule(style: .continuous))
    }
}

@MainActor @Test func pillPrototypesRender() throws {
    for (dark, mode) in [(false, "light"), (true, "dark")] {
        let wallpaper = dark ? [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.26, green: 0.18, blue: 0.30)]
                             : [Color(red: 0.86, green: 0.90, blue: 0.97), Color(red: 0.98, green: 0.88, blue: 0.80)]
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                Rectangle().fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55)).frame(height: 25)  // menu bar
                VStack(spacing: 14) {
                    ForEach(Array([("A", 0), ("B", 1), ("C", 2)]), id: \.0) { name, index in
                        HStack(spacing: 16) {
                            Text(name).font(.system(size: 13, weight: .bold)).foregroundStyle(dark ? .white : .black).frame(width: 16)
                            ForEach(samples.indices, id: \.self) { sampleIndex in
                                switch index {
                                case 0: PrototypeA(sample: samples[sampleIndex])
                                case 1: PrototypeB(sample: samples[sampleIndex])
                                default: PrototypeC(sample: samples[sampleIndex])
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(width: 940, height: 170)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { continue }
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m15-pill-prototypes").standardized
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(mode).png"))
    }
}
