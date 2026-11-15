import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The launcher's window: key (so it can be typed into) without activating Orbit, over full-screen apps too,
/// centred in the upper part of the main display. It closes on Escape, after opening something, or when it
/// loses focus (a click elsewhere).
final class LauncherPanel: NSPanel {
    let model: LauncherModel
    private let open: @MainActor (LauncherItem, Bool) -> Void
    static let size = CGSize(width: 640, height: 430)

    init(model: LauncherModel, open: @escaping @MainActor (LauncherItem, _ alternate: Bool) -> Void) {
        self.model = model
        self.open = open
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        contentView = NSHostingView(rootView: LauncherView(model: model, run: { [weak self] item, alternate in self?.run(item, alternate: alternate) },
                                                           close: { [weak self] in self?.dismiss() }))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShowing: Bool { isVisible }

    func toggle() { isVisible ? dismiss() : present() }

    /// The app that was in front: it gets focus back if the launcher closes without opening anything.
    private var previous: NSRunningApplication?

    func present() {
        model.prepare()
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // Typing needs Orbit active while the launcher is open (macOS's cooperative activation: allowed after the
        // shortcut, a user action). Orbit is an accessory app: no Dock icon, no menu bar of its own.
        NSApp.activate()
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            setFrame(CGRect(x: visible.midX - Self.size.width / 2, y: visible.maxY - visible.height * 0.16 - Self.size.height,
                            width: Self.size.width, height: Self.size.height), display: false)
        }
        makeKeyAndOrderFront(nil)
        LauncherField.focus(in: contentView)
    }

    /// `restoreFocus`: hand focus back to the previous app (not when an item is about to open: that app takes it).
    func dismiss(restoreFocus: Bool = true) {
        guard isVisible else { return }
        orderOut(nil)
        model.reset()
        if restoreFocus { previous?.activate() }
        previous = nil
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { dismiss(restoreFocus: false) }  // something else took focus on purpose
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// ⌘1…⌘8 pick a category; ⌘Return opens the alternate way (reveal in Finder, copy…).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        if let digit = Int(key), (1 ... LauncherCategory.allCases.count).contains(digit) {
            model.category = LauncherCategory.allCases[digit - 1]
            return true
        }
        if key == "\r", let item = model.selected { run(item, alternate: true); return true }
        return super.performKeyEquivalent(with: event)
    }

    private func run(_ item: LauncherItem, alternate: Bool) {
        open(item, alternate)
    }
}

/// The search field: an AppKit text field so arrows, Return, Tab and Escape reach the launcher.
struct LauncherField: NSViewRepresentable {
    let model: LauncherModel
    let run: (Bool) -> Void
    let close: () -> Void

    final class Field: NSTextField {}

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: "Search apps, files, projects, agents, tasks…",
                                                               attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35),
                                                                            .font: NSFont.systemFont(ofSize: 20)])
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel("Search")
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor static func focus(in view: NSView?) {
        guard let view else { return }
        if let field = view as? Field { view.window?.makeFirstResponder(field); return }
        for subview in view.subviews { focus(in: subview) }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherField
        init(parent: LauncherField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            MainActor.assumeIsolated { parent.model.query = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            MainActor.assumeIsolated {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): parent.model.move(-1); return true
                case #selector(NSResponder.moveDown(_:)): parent.model.move(1); return true
                case #selector(NSResponder.insertNewline(_:)): parent.run(false); return true
                case #selector(NSResponder.insertTab(_:)): parent.model.cycleCategory(1); return true
                case #selector(NSResponder.insertBacktab(_:)): parent.model.cycleCategory(-1); return true
                case #selector(NSResponder.cancelOperation(_:)):
                    if parent.model.query.isEmpty { parent.close() } else { parent.model.query = "" }
                    return true
                default: return false
                }
            }
        }
    }
}

struct LauncherView: View {
    let model: LauncherModel
    let run: (LauncherItem, Bool) -> Void
    let close: () -> Void
    var highContrast: Bool { HubAppearance.shared.increasedContrast }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                LauncherField(model: model, run: { alternate in if let item = model.selected { run(item, alternate) } }, close: close)
                    .frame(height: 28)
                if model.isSearchingFiles { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            categories
            Divider().overlay(Color.white.opacity(0.08))
            list
            footer
        }
        .frame(width: LauncherPanel.size.width, height: LauncherPanel.size.height)
        .background(Color(white: 0.07).opacity(0.97), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(highContrast ? 0.5 : 0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var categories: some View {
        HStack(spacing: 4) {
            ForEach(Array(LauncherCategory.allCases.enumerated()), id: \.element) { index, category in
                Button { model.category = category } label: {
                    Text(category.title).font(.system(size: 11.5, weight: model.category == category ? .semibold : .medium))
                        .foregroundStyle(model.category == category ? Color.white : .white.opacity(0.55))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(model.category == category ? Color.white.opacity(0.14) : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
                .help("⌘\(index + 1)")
                .accessibilityAddTraits(model.category == category ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    @ViewBuilder private var list: some View {
        if model.results.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: model.query.isEmpty ? "clock.arrow.circlepath" : "questionmark.circle")
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.3))
                Text(model.message ?? (model.query.isEmpty ? "Things you open appear here." : "Nothing matches “\(model.query)”"))
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5))
                if model.query.isEmpty, !model.memory.recentQueries.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(model.memory.recentQueries.prefix(5), id: \.self) { recent in
                            Button(recent) { model.query = recent }.buttonStyle(.plain)
                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 9).frame(height: 22).background(Color.white.opacity(0.08), in: .capsule)
                        }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        if model.query.isEmpty {
                            Text("Recent").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 4)
                        }
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                            LauncherRow(item: item, selected: index == model.selection)
                                .id(index)
                                .onTapGesture { model.selection = index; run(item, false) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .onChange(of: model.selection) { _, selection in proxy.scrollTo(selection) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Open")
            hint("⌘↩", "Reveal")
            hint("⇥", "Category")
            hint("esc", "Close")
            Spacer()
            if let item = model.selected { Text(item.kind.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4)) }
        }
        .padding(.horizontal, 16).frame(height: 30)
        .background(Color.white.opacity(0.04))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 5).frame(height: 16).background(Color.white.opacity(0.1), in: .rect(cornerRadius: 4))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

private struct LauncherRow: View {
    let item: LauncherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            LauncherIcon(item: item).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(item.kind.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(selected ? 0.7 : 0.35))
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(selected ? Theme.accent.opacity(0.32) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// App and folder icons from Launch Services; files by type (never by reading the file).
private struct LauncherIcon: View {
    let item: LauncherItem

    var body: some View {
        switch item.kind {
        case .app:
            Image(nsImage: LauncherIcons.icon(path: item.path, type: nil)).resizable().interpolation(.high)
        case .file, .folder, .project, .shelf:
            Image(nsImage: LauncherIcons.icon(path: nil, type: item.kind == .file || item.kind == .shelf
                                               ? UTType(filenameExtension: URL(filePath: item.path ?? "").pathExtension) ?? .data : .folder))
                .resizable().interpolation(.high)
        default:
            Image(systemName: item.kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26).background(Theme.accent.opacity(0.15), in: .rect(cornerRadius: 7, style: .continuous))
        }
    }
}

@MainActor
enum LauncherIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(path: String?, type: UTType?) -> NSImage {
        let key = path ?? "type:" + (type?.identifier ?? "data")
        if let cached = cache[key] { return cached }
        let image = path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: type ?? .data)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
