//
//  NewsroomKit.swift — the parts every newsroom edition shares: who this
//  build is (edition, version, links), the About window, the update check,
//  Report a Problem, What's New, Help, and relaunching. HearYe carries a copy
//  of this file; keep the two in step.
//
//  Edition facts come from Info.plist keys that build_app.sh copies in from
//  Editions/<edition>/Edition.plist:
//    NewsroomEdition       "ark" or "public"
//    NewsroomProjectURL    the app's web page
//    NewsroomRepoURL       its GitHub repo (issues), or empty
//    NewsroomUpdateFeed    a GitHub "latest release" API URL, or empty
//    NewsroomSupportEmail  where problem reports go when there is no repo
//

import SwiftUI
import AppKit

enum AppIdentity {
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
    private static func url(_ key: String) -> URL? {
        URL(string: info(key)).flatMap { $0.scheme == nil ? nil : $0 }
    }
    static var name: String { info("CFBundleName").isEmpty ? "App" : info("CFBundleName") }
    static var version: String { info("CFBundleShortVersionString") }
    static var build: String { info("CFBundleVersion") }
    static var edition: String { info("NewsroomEdition").isEmpty ? "ark" : info("NewsroomEdition") }
    static var isPublic: Bool { edition == "public" }
    static var editionLabel: String { isPublic ? "Free edition" : "The Ark edition" }
    static var projectURL: URL? { url("NewsroomProjectURL") }
    static var repoURL: URL? { url("NewsroomRepoURL") }
    static var updateFeed: URL? { url("NewsroomUpdateFeed") }
    static var supportEmail: String { info("NewsroomSupportEmail") }
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Reads a text file shipped in the app's Resources, or "".
    static func resource(_ name: String, _ ext: String) -> String {
        Bundle.main.url(forResource: name, withExtension: ext)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Quits and reopens the app, for settings the engine reads once at launch.
    /// AppKit refuses to quit while a sheet is up, so sheets are closed
    /// first, and the reopen waits until this process has really exited —
    /// `open` on a still-running app only re-activates it.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        for window in NSApp.windows {
            for sheet in window.sheets { window.endSheet(sheet) }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

// MARK: - Update check

/// Asks the edition's release feed whether a newer version exists. Only the
/// version comparison happens here; downloading stays a click in the browser,
/// so nothing is ever installed behind the user's back.
@MainActor final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle, checking, current
        case available(version: String, page: URL)
        case failed(String)
    }
    @Published var state: State = .idle

    private let lastCheckKey = "newsroomLastUpdateCheck"

    var isAvailable: Bool { AppIdentity.updateFeed != nil }

    /// Once a day at most, quietly, at launch.
    func checkInBackgroundIfDue() {
        guard isAvailable else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check() }
    }

    func check() async {
        guard let feed = AppIdentity.updateFeed else { return }
        state = .checking
        var req = URLRequest(url: feed, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 404 {
                // No release published yet: nothing newer than this build.
                state = .current
                return
            }
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                state = .failed("The release page didn't answer as expected.")
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(latest, than: AppIdentity.version) {
                let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? feed
                state = .available(version: latest, page: page)
            } else {
                state = .current
            }
        } catch {
            state = .failed("Couldn't reach the release page. Check the connection and try again.")
        }
    }

    /// Numeric, part by part: 1.10.0 is newer than 1.9.2.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

// MARK: - Report a problem

enum ProblemReport {
    /// Version, system and the app's recent log lines, for the user to read
    /// before sending anything. `subsystem` is the app's os.Logger subsystem.
    static func compose(subsystem: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["show", "--last", "2h", "--style", "compact",
                          "--predicate", "subsystem == \"\(subsystem)\""]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        var logTail = ""
        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            logTail = lines.suffix(200).joined(separator: "\n")
        }
        return """
        What happened (please describe):


        What you expected:


        ---
        \(AppIdentity.name) \(AppIdentity.version) (\(AppIdentity.build)), \(AppIdentity.editionLabel)
        macOS \(AppIdentity.macOS), \(machine())

        Recent log:
        \(logTail.isEmpty ? "(none)" : logTail)
        """
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// A GitHub issue with the report filled in, trimmed to fit a URL.
    static func issueURL(body: String) -> URL? {
        guard let repo = AppIdentity.repoURL else { return nil }
        var c = URLComponents(url: repo.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "title", value: "Problem: "),
                         URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        return c?.url
    }

    static func mailURL(body: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppIdentity.supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: "\(AppIdentity.name) \(AppIdentity.version) problem"),
                        URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        return c.url
    }
}

/// Shows the report so the user sees exactly what would be sent, then hands
/// it to GitHub or Mail. Nothing goes anywhere without that click.
struct ProblemReportView: View {
    let subsystem: String
    @State private var text = "Gathering version and recent log…"

    /// Lives in its own window, so closing means closing that window.
    private func dismiss() { NSApp.keyWindow?.close() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Report a Problem").font(.headline)
            Text("Describe what went wrong at the top. Everything below it is the app version, your macOS version and the app's recent log — read it over and delete anything you'd rather not share.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 560, minHeight: 320)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let url = ProblemReport.issueURL(body: text) {
                    Button("Open on GitHub…") { NSWorkspace.shared.open(url); dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if let url = ProblemReport.mailURL(body: text) {
                    Button("Email…") { NSWorkspace.shared.open(url); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .task {
            let s = subsystem
            text = await Task.detached { ProblemReport.compose(subsystem: s) }.value
        }
    }
}

// MARK: - About

struct AboutView: View {
    /// Third-party notices, plain text; empty hides the section.
    var notices: String = ""
    var pitch: String
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            Text(AppIdentity.name).font(.system(size: 22, weight: .semibold))
            Text("Version \(AppIdentity.version) (\(AppIdentity.build)) · \(AppIdentity.editionLabel)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(pitch).font(.system(size: 12)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if let u = AppIdentity.projectURL { Link("Website", destination: u) }
                if let u = AppIdentity.repoURL { Link("Source & issues", destination: u) }
            }
            .font(.system(size: 12))
            if updates.isAvailable { UpdateStatusRow() }
            VStack(spacing: 3) {
                Text("By Kevin Hessel")
                    .font(.system(size: 11, weight: .medium))
                Text("Built for The Ark, the weekly newspaper serving Tiburon, Belvedere and Strawberry since 1973.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link("thearknewspaper.com", destination: URL(string: "https://www.thearknewspaper.com")!)
                    .font(.system(size: 10))
                Text("Free to use · MIT License")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !notices.isEmpty {
                DisclosureGroup("Acknowledgments") {
                    ScrollView {
                        Text(notices).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 160)
                }
                .font(.system(size: 11))
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct UpdateStatusRow: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        HStack(spacing: 8) {
            switch updates.state {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…")
            case .current:
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("You have the latest version.")
            case .available(let v, let page):
                Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                Text("Version \(v) is available.")
                Button("Download…") { NSWorkspace.shared.open(page) }
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg)
            }
            if updates.state != .checking {
                Button("Check for Updates") { Task { await updates.check() } }
            }
        }
        .font(.system(size: 11))
    }
}

// MARK: - What's New

/// Shown once after each update, from the bundled WhatsNew.txt. Not on a
/// first install — the welcome covers that.
enum WhatsNew {
    private static let key = "newsroomLastSeenVersion"

    /// True when this version is new to a returning user; records it either way.
    static func shouldShow() -> Bool {
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(AppIdentity.version, forKey: key)
        guard let last, last != AppIdentity.version else { return false }
        return !AppIdentity.resource("WhatsNew", "txt").isEmpty
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's new in \(AppIdentity.name) \(AppIdentity.version)").font(.headline)
            ScrollView {
                Text(AppIdentity.resource("WhatsNew", "txt"))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(width: 480, height: 280)
            HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
    }
}

// MARK: - Help

enum HelpBook {
    /// Opens the bundled guide (Help.html) in the browser, where ⌘F searches
    /// it and it works offline. Falls back to the web page.
    static func open(anchor: String? = nil) {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "html") {
            var target = url
            if let anchor, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.fragment = anchor
                target = c.url ?? url
            }
            NSWorkspace.shared.open(target)
        } else if let u = AppIdentity.projectURL {
            NSWorkspace.shared.open(u)
        }
    }
}

/// The standard Help and app-menu items every edition gets. The app declares
/// Window scenes with ids "about" and "report" for these to open.
struct NewsroomCommands: Commands {
    var appHelp: (() -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.name)") { openWindow(id: "about") }
            if AppIdentity.updateFeed != nil {
                Button("Check for Updates…") {
                    openWindow(id: "about")
                    Task { await UpdateChecker.shared.check() }
                }
            }
        }
        CommandGroup(replacing: .help) {
            if let appHelp {
                Button("\(AppIdentity.name) Quick Tips") { appHelp() }
                    .keyboardShortcut("?", modifiers: .command)
            }
            Button("\(AppIdentity.name) Guide") { HelpBook.open() }
            Divider()
            Button("Report a Problem…") { openWindow(id: "report") }
            if let u = AppIdentity.projectURL {
                Button("\(AppIdentity.name) Website") { NSWorkspace.shared.open(u) }
            }
        }
    }
}
