//
//  EngineUpdater.swift — HearYe
//
//  YouTube changes often enough that the yt-dlp bundled at release stops
//  working within weeks. A signed app bundle can't be patched, so a newer
//  yt-dlp (the official single-file release, run by the bundled Python) is
//  kept in Application Support, where the launcher script prefers it. The
//  download is verified against the release's own SHA-256 list before use.
//

import SwiftUI
import AppKit
import CryptoKit

@MainActor final class EngineUpdater: ObservableObject {
    static let shared = EngineUpdater()

    @Published var bundledVersion: String?
    @Published var installedOverride: String?
    @Published var latestVersion: String?
    @Published var status: String?
    @Published var isWorking = false

    private let release = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    var overrideDirectory: URL { MeetingWatcherPaths.stateDirectory.appendingPathComponent("yt-dlp") }
    var overrideFile: URL { overrideDirectory.appendingPathComponent("yt-dlp") }
    private var overrideVersionFile: URL { overrideDirectory.appendingPathComponent("version") }

    /// The version actually in use.
    var activeVersion: String? { installedOverride ?? bundledVersion }

    /// Reads both versions, and drops a fetched copy that a HearYe update
    /// has since overtaken.
    func refresh() async {
        installedOverride = try? String(contentsOf: overrideVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.fileExists(atPath: overrideFile.path) == false { installedOverride = nil }
        bundledVersion = await Task.detached { Self.runBundledVersion() }.value
        if let o = installedOverride, let b = bundledVersion, !Self.isNewer(o, than: b) {
            try? FileManager.default.removeItem(at: overrideDirectory)
            installedOverride = nil
        }
    }

    /// Once a day: refresh, look up the latest, and quietly install it.
    func updateInBackgroundIfDue() {
        let key = "engineLastCheck"
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: key) > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        Task { await update(quiet: true) }
    }

    func update(quiet: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await refresh()
        if !quiet { status = "Checking for a newer yt-dlp…" }
        do {
            var req = URLRequest(url: release, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let assets = obj["assets"] as? [[String: Any]] else { throw Failure("unexpected reply") }
            latestVersion = tag
            if let active = activeVersion, !Self.isNewer(tag, than: active) {
                if !quiet { status = "yt-dlp \(active) is the latest." }
                return
            }
            func asset(_ name: String) -> URL? {
                assets.first { $0["name"] as? String == name }
                    .flatMap { $0["browser_download_url"] as? String }
                    .flatMap(URL.init(string:))
            }
            guard let binURL = asset("yt-dlp"), let sumsURL = asset("SHA2-256SUMS") else {
                throw Failure("the release is missing its files")
            }
            status = "Downloading yt-dlp \(tag)…"
            let (sums, _) = try await URLSession.shared.data(from: sumsURL)
            let (bin, _) = try await URLSession.shared.data(from: binURL)
            let expected = String(decoding: sums, as: UTF8.self)
                .split(separator: "\n")
                .first { $0.hasSuffix(" yt-dlp") }?
                .split(separator: " ").first.map(String.init)
            let actual = SHA256.hash(data: bin).map { String(format: "%02x", $0) }.joined()
            guard let expected, expected.lowercased() == actual else {
                throw Failure("the download didn't match its published checksum, so it wasn't used")
            }
            try FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
            let staging = overrideDirectory.appendingPathComponent("yt-dlp.new")
            try bin.write(to: staging, options: .atomic)
            _ = try? FileManager.default.removeItem(at: overrideFile)
            try FileManager.default.moveItem(at: staging, to: overrideFile)
            try tag.write(to: overrideVersionFile, atomically: true, encoding: .utf8)
            installedOverride = tag
            status = "Updated to yt-dlp \(tag)."
        } catch {
            if !quiet {
                let detail = (error as? Failure)?.message ?? "couldn't reach GitHub — check the connection"
                status = "Update failed: \(detail)."
            }
        }
    }

    /// Goes back to the copy that shipped with HearYe.
    func revertToBundled() {
        try? FileManager.default.removeItem(at: overrideDirectory)
        installedOverride = nil
        status = "Using the yt-dlp bundled with HearYe."
    }

    nonisolated private static func runBundledVersion() -> String? {
        guard let launcher = Bundle.main.resourceURL?.appendingPathComponent("bin/yt-dlp").path,
              FileManager.default.isExecutableFile(atPath: launcher) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launcher)
        task.arguments = ["--version"]
        var env = ProcessInfo.processInfo.environment
        env["HEARYE_YTDLP_BUNDLED"] = "1"
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let v = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// yt-dlp versions are dates: 2026.08.19, sometimes with a fourth part.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        UpdateChecker.isNewer(a, than: b)
    }

    private struct Failure: Error { let message: String; init(_ m: String) { message = m } }
}

/// A small window: which yt-dlp is in use, and buttons to update or revert.
struct EngineUpdateView: View {
    @ObservedObject private var engine = EngineUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download engine").font(.headline)
            Text("HearYe downloads with yt-dlp, which has to keep up with YouTube's changes. HearYe checks for a new version once a day and installs it after verifying its checksum; you can also do it here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("In use:").foregroundStyle(.secondary); Text(engine.activeVersion ?? "…") }
                GridRow { Text("Bundled:").foregroundStyle(.secondary); Text(engine.bundledVersion ?? "…") }
                if let latest = engine.latestVersion {
                    GridRow { Text("Latest:").foregroundStyle(.secondary); Text(latest) }
                }
            }
            .font(.system(size: 12))
            if let status = engine.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                if engine.installedOverride != nil {
                    Button("Use Bundled Version") { engine.revertToBundled() }
                }
                Spacer()
                if engine.isWorking { ProgressView().controlSize(.small) }
                Button("Update yt-dlp") { Task { await engine.update() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(engine.isWorking)
            }
        }
        .padding(18)
        .frame(width: 420)
        .task { await engine.refresh() }
    }
}
