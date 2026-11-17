import Foundation

// Launcher extras (Milestone 20): a calculator and Apple Shortcuts.
// - The calculator is a small arithmetic parser (no NSExpression, which raises
//   on bad input, and nothing is ever evaluated as code). Return copies the result.
// - Shortcuts come from macOS's own `shortcuts` command: `list` for names, and
//   `run` only when you press Return on one (⌘Return opens it in Shortcuts instead).

enum Calculator {
    /// The value of an arithmetic expression: + − × ÷ * / % ^, parentheses, unary minus, decimals,
    /// and `pi`. nil for anything else, or for a bare number (that's a search, not a sum).
    static func evaluate(_ text: String) -> Double? {
        guard !looksLikeAnIdentifier(text) else { return nil }
        var parser = Parser(Array(text.lowercased().replacingOccurrences(of: "pi", with: "π")))
        guard text.contains(where: \.isNumber), let value = parser.expression(), parser.atEnd, parser.sawOperator,
              value.isFinite else { return nil }
        return value
    }

    /// Dates, phone numbers and versions ("2024-11-17", "555-1234", "12/25/2024", "1.2.3") are searches, not sums:
    /// no spaces, and only "-", "/" or "." between groups of digits. With spaces ("10 - 3") it's arithmetic.
    static func looksLikeAnIdentifier(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), trimmed.allSatisfy({ $0.isNumber || "-/.".contains($0) }) else { return false }
        let separators = trimmed.filter { "-/".contains($0) }.count
        return trimmed.contains("-") || separators >= 2 || trimmed.filter { $0 == "." }.count >= 2
    }

    /// "42", "3.1415926536", "1,234,567" (grouped for reading), up to 10 decimals, no trailing zeros.
    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...10)))
    }

    /// What Return copies: no grouping and a "." decimal point, so it pastes into code and other apps as a number.
    static func plain(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...10)).locale(Locale(identifier: "en_US_POSIX")))
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var sawOperator = false

        init(_ characters: [Character]) { self.characters = characters.filter { !$0.isWhitespace && $0 != "," } }

        var atEnd: Bool { index == characters.count }
        private var peek: Character? { index < characters.count ? characters[index] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek, "+-−".contains(op) {
                index += 1
                sawOperator = true
                guard let right = term() else { return nil }
                value = op == "+" ? value + right : value - right
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let op = peek, "*/×÷%x".contains(op) {
                index += 1
                sawOperator = true
                guard let right = unary() else { return nil }
                switch op {
                case "*", "×", "x": value *= right
                case "%": guard right != 0 else { return nil }; value = value.truncatingRemainder(dividingBy: right)
                default: guard right != 0 else { return nil }; value /= right
                }
            }
            return value
        }

        /// A sign applies to the whole power: -2^2 = -(2^2) = -4.
        private mutating func unary() -> Double? {
            if let sign = peek, "-−".contains(sign) {
                index += 1
                return unary().map { -$0 }
            }
            if peek == "+" { index += 1; return unary() }
            return power()
        }

        private mutating func power() -> Double? {
            guard let base = primary() else { return nil }
            if peek == "^" {
                index += 1
                sawOperator = true
                guard let exponent = unary() else { return nil }  // right-associative (2^3^2 = 2^9); 2^-1 = 0.5
                return Foundation.pow(base, exponent)
            }
            return base
        }

        private mutating func primary() -> Double? {
            if peek == "(" {
                index += 1
                guard let value = expression(), peek == ")" else { return nil }
                index += 1
                sawOperator = true  // "(5)" is a calculation, not a search
                return value
            }
            if peek == "π" { index += 1; sawOperator = true; return .pi }
            let start = index
            while let c = peek, c.isNumber || c == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(characters[start..<index]))
        }
    }
}

/// Apple Shortcuts by name, from `/usr/bin/shortcuts list`.
enum ShortcutsCatalog {
    static let tool = URL(filePath: "/usr/bin/shortcuts")

    nonisolated static func list() -> [String] {
        guard FileManager.default.isExecutableFile(atPath: tool.path(percentEncoded: false)),
              let output = run(["list"]) else { return [] }
        return parse(output)
    }

    /// One name per line, blanks dropped, duplicates once.
    nonisolated static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Runs a shortcut by name (an argument, never a shell string), in the background.
    nonisolated static func runShortcut(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = run(["run", name]) }
    }

    /// Opens the shortcut in the Shortcuts app for editing.
    static func editURL(_ name: String) -> URL? {
        var components = URLComponents(string: "shortcuts://open-shortcut")
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        return components?.url
    }

    private nonisolated static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
