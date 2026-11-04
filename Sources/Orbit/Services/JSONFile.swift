import Foundation

/// Orbit's own data folder, ~/Library/Application Support/Orbit. It is inside
/// the user's Library, so no privacy permission is involved.
enum OrbitStorage {
    static var directory: URL {
        #if DEBUG
        // Debug builds only: point Orbit at a disposable folder for UI checks
        // without touching real data (ORBIT_DATA_DIR=/tmp/x …/Orbit).
        if let override = ProcessInfo.processInfo.environment["ORBIT_DATA_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Orbit", directoryHint: .isDirectory)
    }
}

/// One Codable value stored as a JSON file, written atomically.
struct JSONFile<Value: Codable> {
    let url: URL

    /// nil when the file doesn't exist yet. Throws when it exists but can't be
    /// decoded, so callers can refuse to overwrite data they couldn't read.
    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// A value backed by a `JSONFile`. If the file exists but can't be read, the
/// value starts from `initial`, `problem` says why, and every later change is
/// refused so the unreadable file is never overwritten.
struct Persisted<Value: Codable> {
    private(set) var value: Value
    private(set) var problem: String?
    private let file: JSONFile<Value>?
    /// Where the existing file is copied before this run's first write (once;
    /// an existing backup is never replaced). nil once done or not wanted.
    private var backup: URL?

    /// Not saved anywhere (tests).
    init(memory value: Value) {
        self.value = value
        file = nil
    }

    init(_ file: JSONFile<Value>, initial: Value, backupName: String? = nil) {
        self.file = file
        backup = backupName.map { file.url.deletingLastPathComponent().appending(path: $0) }
        do {
            value = try file.load() ?? initial
        } catch {
            value = initial
            problem = "Couldn't read \(file.url.lastPathComponent). It was left untouched."
        }
    }

    /// Applies a change and saves it; does nothing while `problem` is set.
    mutating func update(_ change: (inout Value) -> Void) {
        guard problem == nil else { return }
        change(&value)
        save()
    }

    /// An explicit user reset: starts over even after a read problem. An
    /// unreadable file is first moved aside (never overwritten).
    mutating func replace(with newValue: Value) {
        if problem != nil, let file {
            let aside = file.url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            guard (try? FileManager.default.moveItem(at: file.url, to: aside)) != nil else { return }
        }
        problem = nil
        value = newValue
        save()
    }

    private mutating func save() {
        guard let file else { return }
        if let backup {
            let manager = FileManager.default
            if manager.fileExists(atPath: file.url.path(percentEncoded: false)),
               !manager.fileExists(atPath: backup.path(percentEncoded: false)) {
                do {
                    try manager.copyItem(at: file.url, to: backup)
                } catch {
                    problem = "Couldn't back up \(file.url.lastPathComponent), so nothing was saved."
                    return
                }
            }
            self.backup = nil
        }
        do {
            try file.save(value)
        } catch {
            problem = "Couldn't save \(file.url.lastPathComponent)."
        }
    }
}
