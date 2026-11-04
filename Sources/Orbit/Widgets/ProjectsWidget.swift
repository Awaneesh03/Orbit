import SwiftUI

/// Project folders in ~/Developer (Git repositories marked) with one-click
/// open in VS Code, Terminal or Finder. Live: rescans the folder list each
/// time it appears (no watching).
@MainActor @Observable
final class ProjectsWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "projects", title: "Projects", description: "Open your project folders in VS Code, Terminal or Finder",
        symbol: "folder", category: .developer, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded, isEnabledByDefault: false)
    private(set) var projects: [Project]
    let root: URL
    private let didLaunch: @MainActor () -> Void

    var state: WidgetState {
        projects.isEmpty ? .empty("No folders in \(Self.abbreviated(root))") : .ready
    }

    init(root: URL, didLaunch: @escaping @MainActor () -> Void) {
        self.root = root
        self.didLaunch = didLaunch
        projects = ProjectScanner.projects(in: root)
    }

    func start() { projects = ProjectScanner.projects(in: root) }

    func open(_ project: Project, with action: ProjectAction) {
        action.open(project)
        didLaunch()
    }

    nonisolated static func abbreviated(_ url: URL) -> String {
        url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        let actions = ProjectAction.allCases.filter(\.isAvailable)
        let shown = presentation == .compact ? Array(projects.prefix(3)) : projects
        return AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown) { project in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name).lineLimit(1)
                            Text((project.isGitRepository ? "Git · " : "")
                                 + project.modified.formatted(.relative(presentation: .named)))
                                .foregroundStyle(Theme.tertiary)
                        }
                        Spacer(minLength: 6)
                        ForEach(actions) { action in
                            Button { self.open(project, with: action) } label: {
                                Image(systemName: action.symbol)
                                    .frame(width: 26, height: 22)
                                    .orbitSurface(radius: 7)
                            }
                            .buttonStyle(DashboardButtonStyle())
                            .help("Open in \(action.title)")
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never))
    }
}
