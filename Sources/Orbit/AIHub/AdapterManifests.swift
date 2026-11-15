import Foundation
import OrbitBridge

// Third-party agent adapters (Phase 12; docs/AI_HUB_SPEC.md §4 J): a JSON
// manifest describing where an agent's hook payloads keep their fields, using
// the same `HookAdapter.Mapping` as Orbit's own adapters. Declarative only —
// no code is loaded or run. Permission boundary: a manifest can only observe;
// any answering fields are dropped, IDs can't shadow a built-in or simulated
// agent, and bad files are reported and skipped, never fatal. Installing one
// is copying a file into the folder; removing it is deleting the file.

struct AdapterManifest: Codable, Equatable, Sendable {
    static let schema = 1
    static let maxBytes = 64 * 1024

    let id: String
    let name: String
    let version: String
    /// The oldest manifest schema this file needs (only 1 exists; missing means 1).
    var minOrbitSchema: Int?
    let mapping: HookAdapter.Mapping
}

enum AdapterManifests {
    struct Loaded: Equatable, Sendable {
        var adapters: [String: AdapterManifest] = [:]
        /// File name → why it was skipped.
        var problems: [String: String] = [:]
    }

    static var folder: URL { OrbitStorage.directory.appending(path: "AIHub/Adapters") }

    /// Every valid manifest in `folder` (reading never writes).
    static func load(from folder: URL = folder, reserved: Set<String>) -> Loaded {
        var loaded = Loaded()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(50) {
            let name = file.lastPathComponent
            // Regular files only (a symlink to /dev/zero or a pipe would never end), and never more than the cap read.
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= AdapterManifest.maxBytes,
                  let handle = try? FileHandle(forReadingFrom: file),
                  let data = try? handle.read(upToCount: AdapterManifest.maxBytes + 1), data.count <= AdapterManifest.maxBytes else {
                loaded.problems[name] = "Too large or unreadable"
                continue
            }
            guard let manifest = try? JSONDecoder().decode(AdapterManifest.self, from: data) else {
                loaded.problems[name] = "Not a valid adapter manifest"
                continue
            }
            if let problem = validate(manifest, reserved: reserved.union(loaded.adapters.keys)) {
                loaded.problems[name] = problem
                continue
            }
            loaded.adapters[manifest.id] = manifest
        }
        return loaded
    }

    /// nil when acceptable.
    static func validate(_ manifest: AdapterManifest, reserved: Set<String>) -> String? {
        guard let id = AgentID(manifest.id), !id.isDemo else { return "Invalid agent ID" }
        guard !reserved.contains(manifest.id) else { return "\(manifest.id) is already taken" }
        guard (manifest.minOrbitSchema ?? 1) <= AdapterManifest.schema else { return "Needs a newer Orbit" }
        guard (1 ... 60).contains(manifest.name.count), (1 ... 20).contains(manifest.version.count) else { return "Invalid name or version" }
        let mapping = manifest.mapping
        guard !mapping.session.isEmpty, !mapping.events.isEmpty, mapping.events.count <= 64,
              mapping.events.keys.allSatisfy(AgentEnvelopeRules.isValidEvent) else { return "Invalid mapping" }
        return nil
    }

    /// The manifest as an adapter that can only observe (answering fields dropped).
    static func adapter(_ manifest: AdapterManifest) -> HookAdapter {
        var mapping = manifest.mapping
        mapping.permissionEvent = nil
        mapping.allowOutput = nil
        mapping.denyOutput = nil
        return HookAdapter(manifest: AgentManifest(id: AgentID(manifest.id)!, displayName: manifest.name, capabilities: .observe), mapping: mapping)
    }
}

private enum AgentEnvelopeRules {
    static func isValidEvent(_ name: String) -> Bool { AgentEnvelope.isValidEventName(name) }
}

extension AgentRegistry {
    /// Orbit's adapters followed by the manifests' (which can't replace them).
    func adding(_ manifests: [AdapterManifest]) -> AgentRegistry {
        let ids = Set(adapters.map(\.manifest.id.rawValue))
        let extra = manifests.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id }.map(AdapterManifests.adapter)
        guard let last = adapters.last else { return AgentRegistry(adapters: extra) }
        return AgentRegistry(adapters: adapters.dropLast() + extra + [last])  // the demo adapter (catch-all for demo-) stays last
    }
}
