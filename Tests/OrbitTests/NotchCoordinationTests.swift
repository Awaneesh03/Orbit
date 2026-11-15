import Foundation
import Testing
@testable import Orbit

// Coexistence with Coucou (docs/AI_HUB_SPEC.md §21): read-only detection of
// both installed copies, launch/quit transitions, the notch table (Orbit's
// priorities unchanged; only agent alerts and the Notch Companion yield),
// alert routing, where a waiting Claude session is answered, and the pet's
// agent mood.

private let applications = URL(filePath: "/Applications/Coucou.app")
private let desktop = URL(filePath: "/Users/me/Desktop/Coucou 2.app")
private let developerID = "fr.louisraille.NotchBuddy"

/// What a fake Mac shows Orbit: installed copies and running apps, changeable between looks.
@MainActor
private final class FakeMac {
    var installed: [URL] = [applications, desktop]
    var running: [(bundleID: String?, url: URL?)] = [("com.apple.finder", URL(filePath: "/System/Library/CoreServices/Finder.app"))]
    var installedLookups = 0

    var sources: CoucouPresence.Sources {
        CoucouPresence.Sources(installed: { [unowned self] ids in
            installedLookups += 1
            return ids.contains(developerID) ? installed : []
        }, running: { [unowned self] in running })
    }

    func launch(_ url: URL, id: String = developerID) { running.append((id, url)) }
    func quit(_ url: URL) { running.removeAll { $0.url == url } }
}

@MainActor @Test func bothInstalledCopiesAreSeenAndRunningTellsWhichOne() {
    let ids = CoucouPresence.bundleIDs
    let notInstalled = CoucouPresence.state(installed: [], running: [], bundleIDs: ids)
    #expect(notInstalled.kind == .notInstalled && notInstalled.summary == "not installed")

    let installed = CoucouPresence.state(installed: [applications, desktop], running: [], bundleIDs: ids)
    #expect(installed.kind == .installed && !installed.isRunning && installed.installed == [applications, desktop])
    #expect(installed.summary == "installed, not running (2 copies)")

    let fromDesktop = CoucouPresence.state(installed: [applications, desktop], running: [(developerID, desktop)], bundleIDs: ids)
    #expect(fromDesktop.kind == .running && fromDesktop.running == [desktop] && fromDesktop.installed.count == 2)
    #expect(fromDesktop.summary == "running · /Users/me/Desktop/Coucou 2.app")

    let fromApplications = CoucouPresence.state(installed: [applications, desktop], running: [(developerID, applications)], bundleIDs: ids)
    #expect(fromApplications.running == [applications])

    // A copy Launch Services doesn't list yet still counts once it runs; the App Store build counts too.
    let unlisted = CoucouPresence.state(installed: [], running: [("fr.louisraille.Coucou", URL(filePath: "/Applications/Coucou.app/"))], bundleIDs: ids)
    #expect(unlisted.isRunning && unlisted.installed.count == 1)
    // Look-alikes don't: identity is the bundle ID, never a name or folder.
    let lookAlikes = CoucouPresence.state(installed: [], running: [("com.example.Coucou", applications), (nil, desktop), ("fr.louisraille.NotchBuddyHelper", desktop)], bundleIDs: ids)
    #expect(lookAlikes.kind == .notInstalled)
}

@MainActor @Test func launchAndQuitAreReportedOnceEachAndOtherAppsAreIgnored() {
    let mac = FakeMac()
    let presence = CoucouPresence(sources: mac.sources)
    var seen: [CoucouPresence.State.Kind] = []
    presence.onChange = { seen.append($0.kind) }
    presence.refresh(force: true)  // what start() does first
    #expect(seen == [.installed] && mac.installedLookups == 1)

    mac.launch(desktop)  // ~/Desktop/Coucou 2.app launches
    presence.refresh()
    #expect(seen == [.installed, .running] && presence.state.running == [desktop])

    mac.running.append(("com.apple.TextEdit", URL(filePath: "/System/Applications/TextEdit.app")))  // unrelated launch
    presence.refresh()
    #expect(seen.count == 2 && mac.installedLookups == 2)  // no callback, no Launch Services lookup

    mac.quit(desktop)
    presence.refresh()
    #expect(seen == [.installed, .running, .installed] && !presence.state.isRunning)

    mac.launch(applications)  // then the /Applications copy
    presence.refresh()
    #expect(seen.last == .running && presence.state.running == [applications])
    presence.refresh()  // nothing changed: nothing reported
    #expect(seen.count == 4)

    mac.quit(applications)
    mac.installed = []  // and both copies were deleted meanwhile
    presence.refresh()
    #expect(seen.last == .notInstalled)
}

@Test func theTableKeepsOrbitsOverlayPrioritiesWhoeverOwnsTheNotch() {
    let phases: [MusicIsland.Phase] = [.hidden, .compact, .expanded, .dismissed]
    for owner in [NotchCoordination.Owner.orbit, .coucou] {
        for dashboard in [false, true] {
            for island in phases {
                for volume in [false, true] {
                    for alert in [false, true] {
                        for companion in [false, true] {
                            let inputs = NotchCoordination.Inputs(owner: owner, dashboardOpen: dashboard, island: island,
                                                                  volumeHUD: volume, alert: alert, companion: companion)
                            let holder = NotchCoordination.holder(inputs)
                            let overlay: NotchOverlay = switch holder {
                            case .expandedMusic, .compactMusic: .musicIsland
                            case .volumeHUD: .volumeHUD
                            default: .none
                            }
                            if owner == .orbit {  // exactly the approved coordinator's choice
                                #expect(overlay == NotchOverlayCoordinator.decide(dashboardOpen: dashboard, island: island, volumeVisible: volume))
                            } else {  // §22: under Coucou only the dashboard (opened from ⌃⌥⌘O) is left
                                #expect(holder == (dashboard ? .dashboard : nil))
                            }
                            if dashboard { #expect(holder == .dashboard) }
                        }
                    }
                }
            }
        }
    }
}

@Test func coucouTakesEverythingButTheDashboard() {
    for surface in NotchCoordination.Surface.allCases {
        #expect(NotchCoordination.permits(surface, owner: .orbit))
        #expect(NotchCoordination.permits(surface, owner: .coucou) == (surface == .dashboard))  // §22, decision 2
    }
    var inputs = NotchCoordination.Inputs(alert: true, companion: true)
    #expect(NotchCoordination.holder(inputs) == .agentAlert)  // the alert before the companion
    inputs.alert = false
    #expect(NotchCoordination.holder(inputs) == .companion)
    inputs.owner = .coucou
    #expect(NotchCoordination.holder(inputs) == nil)  // Coucou's island is there: no second mascot
    inputs.alert = true
    #expect(NotchCoordination.holder(inputs) == nil)
    inputs.island = .compact
    #expect(NotchCoordination.holder(inputs) == nil)  // Music Island steps aside too (it would sit under Coucou's island)
    #expect(NotchCoordination.Owner(coucouRunning: true) == .coucou && NotchCoordination.Owner(coucouRunning: false) == .orbit)
}

@Test func theAlertOnlyTakesAFreeSlot() {
    func shows(_ inputs: NotchCoordination.Inputs) -> Bool { NotchCoordination.holder(inputs) == .agentAlert }
    #expect(shows(.init(alert: true)))
    #expect(!shows(.init(volumeHUD: true, alert: true)))
    #expect(!shows(.init(island: .compact, alert: true)) && !shows(.init(island: .expanded, alert: true)))
    #expect(!shows(.init(dashboardOpen: true, alert: true)))
    #expect(!shows(.init()))
    #expect(!shows(.init(owner: .coucou, alert: true)))
}

@MainActor @Test func whileCoucouRunsAlertsStayOutOfTheNotchButMonitoringCarriesOn() {
    let scheduler = FakeScheduler()
    let alerts = AgentAlerts(scheduler: scheduler)
    let sessions = AgentSessionManager(scheduler: scheduler)
    let key = SessionKey(agent: AgentID("claude-code")!, nativeID: "s1")!
    let waiting = AgentEvent(id: UUID(), session: key, kind: .waitingForUser, nativeName: "Notification", occurredAt: nil, receivedAt: .now,
                             cwd: "/tmp/p", tool: nil, summary: "Waiting for you", files: [], dedupeKey: "w1")
    // What the app does when Coucou launches: the preference is on, the table says no.
    alerts.isEnabled = NotchCoordination.permits(.agentAlert, owner: .coucou)
    alerts.receive([waiting])
    sessions.apply([waiting])
    #expect(alerts.current == nil && alerts.queue.isEmpty)  // nothing below the notch
    #expect(sessions.sessions[key]?.status == .waiting)  // still monitored and listed

    alerts.isEnabled = NotchCoordination.permits(.agentAlert, owner: .orbit)  // Coucou quit
    let failed = AgentEvent(id: UUID(), session: key, kind: .error, nativeName: "StopFailure", occurredAt: nil, receivedAt: .now,
                            cwd: "/tmp/p", tool: nil, summary: "rate limited", files: [], dedupeKey: "f1")
    alerts.receive([failed])
    #expect(alerts.current?.text == "Claude Code: rate limited")
}

@MainActor @Test func aWaitingClaudeSessionSaysWhereToAnswer() {
    func session(_ bundle: String?, _ status: AgentSession.Status = .waiting, agent: String = "claude-code") -> AgentSession {
        AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: "s")!, status: status, startedAt: .now, lastEventAt: .now, originBundleID: bundle)
    }
    let vscode = session("com.microsoft.VSCode"), cursor = session("com.todesktop.230313mzl4w4u92"), terminal = session("com.apple.Terminal")
    #expect(WaitingPlace.of(vscode, coucouAnswersClaude: true) == .coucou)
    #expect(WaitingPlace.of(cursor, coucouAnswersClaude: true) == .coucou)
    #expect(WaitingPlace.of(terminal, coucouAnswersClaude: true) == .terminal)  // Coucou 0.2.2 sends terminals back
    #expect(WaitingPlace.of(vscode, coucouAnswersClaude: false) == .terminal)  // Coucou not running
    #expect(WaitingPlace.of(session(nil), coucouAnswersClaude: true) == .terminal)
    #expect(WaitingPlace.of(session("com.microsoft.VSCode", agent: "codex"), coucouAnswersClaude: true) == nil)  // Claude only
    #expect(WaitingPlace.of(session("com.microsoft.VSCode", .running), coucouAnswersClaude: true) == nil)
    #expect(WaitingPlace.coucou.label == "Answer in Coucou" && WaitingPlace.terminal.label == "Waiting in terminal")
    #expect(HubStatus.of(.waiting, waiting: .coucou).label == "Answer in Coucou")
    #expect(HubStatus.of(.waiting, waiting: .terminal).label == "Waiting in terminal")
    #expect(HubStatus.of(.waiting).label == "Needs you · inferred")  // other agents unchanged

    let hub = AIHubService(paths: .init(socket: "/tmp/unused.sock", store: URL(filePath: "/tmp/unused.sqlite"),
                                        demoStore: URL(filePath: "/tmp/unused-demo.sqlite")), scheduler: FakeScheduler(), discover: { [] })
    #expect(hub.waitingPlace(of: vscode) == .terminal)
    hub.coucouAnswersClaude = true
    #expect(hub.waitingPlace(of: vscode) == .coucou)
}

@Test func coucouAnswersClaudeOnlyWithItsOwnPermissionHook() {
    func settings(_ json: String) -> Data { Data(json.utf8) }
    #expect(ClaudeHookInstaller.coucouAnswersPermissions(in: settings(
        #"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\"","timeout":120}]}]}}"#)))
    #expect(!ClaudeHookInstaller.coucouAnswersPermissions(in: settings(
        #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"nb-hook"}]}]}}"#)))  // observing only
    #expect(!ClaudeHookInstaller.coucouAnswersPermissions(in: settings(
        #"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"/other/approver"}]}]}}"#)))
    #expect(!ClaudeHookInstaller.coucouAnswersPermissions(in: settings("not json")))
    #expect(!ClaudeHookInstaller.coucouAnswersPermissions(in: nil))
}

@MainActor @Test func thePetHearsTheAgentsWithoutASecondMascot() {
    func session(_ id: String, _ status: AgentSession.Status, agent: String = "claude-code", ago: TimeInterval = 0) -> AgentSession {
        AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: id)!, status: status, startedAt: .now - ago, lastEventAt: .now - ago)
    }
    #expect(AgentMood.of([AgentSession]()) == .none)
    #expect(AgentMood.of([session("a", .running)]) == .working)
    #expect(AgentMood.of([session("a", .running), session("b", .failed)]) == .failed)
    #expect(AgentMood.of([session("a", .failed), session("b", .waiting), session("c", .running)]) == .needsYou)
    #expect(AgentMood.of([session("a", .failed, ago: 3600), session("b", .completed)]) == .none)  // an old failure is let go
    #expect(AgentMood.of([session("a", .waiting, agent: "demo-alpha")]) == .none)  // simulated agents don't move the pet

    // One cat: the Notch Companion steps aside while Coucou has the notch; the Desktop Pet doesn't.
    let activity = PetActivity(scheduler: FakeScheduler())
    let pet = PetModel(activity: activity, scheduler: FakeScheduler())
    pet.toggles = .init(pet: true, desktop: true, companion: true)
    activity.setCompanionOccluded(!NotchCoordination.permits(.companion, owner: .coucou))
    #expect(!pet.companionVisible && pet.desktopVisible)
    activity.setCompanionOccluded(!NotchCoordination.permits(.companion, owner: .orbit))
    #expect(pet.companionVisible)
    let before = pet.state
    pet.agentMood = .needsYou
    #expect(pet.state == before && pet.agentMood == .needsYou)  // the mood changes nothing yet: a later stage draws it
}
