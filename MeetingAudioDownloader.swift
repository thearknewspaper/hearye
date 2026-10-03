import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications
import os

private let downloaderUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"

private let downloadLog = Logger(subsystem: "com.kevin.hearye", category: "download")
private let watcherLog = Logger(subsystem: "com.kevin.hearye", category: "watcher")

/// Vimeo walls its watch pages behind a login and its player endpoints behind
/// TLS fingerprinting, but embeddable videos still play anonymously through
/// the embed player. Rewrite a vimeo.com link to the embed player and have
/// yt-dlp impersonate a real browser — the bundled curl_cffi supplies the
/// TLS disguise. Returns nil for anything that is not a Vimeo video link.
private func vimeoAdjustment(for url: String) -> (url: String, extraArguments: [String])? {
    guard let regex = try? NSRegularExpression(
        pattern: #"(?:player\.)?vimeo\.com/(?:video/)?(\d+)(?:/([0-9a-f]+))?"#),
        let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
        let idRange = Range(match.range(at: 1), in: url) else { return nil }
    var playerURL = "https://player.vimeo.com/video/\(url[idRange])"
    if let hashRange = Range(match.range(at: 2), in: url) {
        // Unlisted videos carry their access hash in the path; the embed
        // player wants it as ?h=.
        playerURL += "?h=\(url[hashRange])"
    }
    return (playerURL, ["--impersonate", "chrome"])
}

/// Shared by the GUI model and the headless channel watcher, which runs
/// outside the main actor and therefore cannot use DownloaderModel's statics.
private func bundledExecutable(named name: String) -> String? {
    var candidates: [String] = []
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path {
        candidates.append(bundled)
    }
    candidates += [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)"
    ]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

private enum AudioFormat: String, CaseIterable, Identifiable {
    case m4a
    case wav

    var id: String { rawValue }

    var label: String {
        switch self {
        case .m4a: return "M4A (compact, recommended)"
        case .wav: return "WAV (large, uncompressed)"
        }
    }
}

/// How much the app actually knows about a link before downloading it.
/// Only `.confirmed` earns a verification badge in the UI — anything else is
/// a guess that yt-dlp will test at download time.
private enum ProbeConfidence {
    case confirmed      // a real media source was located
    case likely         // yt-dlp reported a title, so the URL resolves
    case unverified     // nothing was checked; yt-dlp will find out

    var systemImage: String {
        switch self {
        case .confirmed: return "checkmark.seal.fill"
        case .likely: return "checkmark.circle"
        case .unverified: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .confirmed: return .green
        case .likely: return .accentColor
        case .unverified: return .secondary
        }
    }
}

private struct ProbeResult {
    let inputURL: URL
    let downloadURL: URL
    let refererURL: URL?
    let title: String
    let kind: String
    let detail: String
    var confidence: ProbeConfidence
}

private enum ResolverError: LocalizedError {
    case invalidURL
    case unavailable(String)
    case noMediaFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a complete public URL, including https://."
        case .unavailable(let message):
            return message
        case .noMediaFound:
            return "The page loaded, but no public audio/video source was found."
        }
    }
}

/// Only http(s) targets may ever be handed to yt-dlp or re-fetched. Scraped page
/// content is untrusted: without this a crafted page could point the downloader at
/// file://, data://, or a host on the loopback/link-local range.
private func isAllowedMediaURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
    if host == "localhost" || host.hasSuffix(".localhost") { return false }
    if host == "127.0.0.1" || host.hasPrefix("127.") || host == "::1" { return false }
    if host.hasPrefix("169.254.") { return false }          // link-local / cloud metadata
    if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return false }
    return true
}

private func isGranicusHost(_ host: String) -> Bool {
    let h = host.lowercased()
    return h == "granicus.com" || h.hasSuffix(".granicus.com")
}

/// Decode only whole UTF-8 sequences out of `buffer`, leaving any trailing partial
/// sequence in place for the next read. Previously a chunk boundary landing inside a
/// multi-byte character discarded the entire 8 KB read.
private func decodeAvailableUTF8(_ buffer: inout Data) -> String? {
    guard !buffer.isEmpty else { return nil }
    if let whole = String(data: buffer, encoding: .utf8) {
        buffer.removeAll(keepingCapacity: true)
        return whole
    }
    var drop = 1
    while drop <= 3 && drop < buffer.count {
        let head = buffer.prefix(buffer.count - drop)
        if let text = String(data: head, encoding: .utf8) {
            buffer = Data(buffer.suffix(drop))
            return text
        }
        drop += 1
    }
    return nil
}

/// Strip invisible and control characters that ride along when a URL is copied out of
/// a PDF agenda, an email body, or a web page. These are the main reason a pasted URL
/// fails to round-trip through URL(string:).
private func sanitizeURLText(_ raw: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in raw.unicodeScalars {
        if scalar.properties.isDefaultIgnorableCodePoint { continue }
        if CharacterSet.controlCharacters.contains(scalar) { continue }
        scalars.append(scalar)
    }
    return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Resumes a continuation at most once, from whichever of the termination handler,
/// launch failure, or timeout gets there first.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

private struct SourceResolver {
    // One session for the process rather than one per inspection, which previously
    // leaked a URLSession on every attempt.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": downloaderUserAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    private static let maximumPageBytes = 8 * 1024 * 1024

    func resolve(_ input: URL) async throws -> ProbeResult {
        let host = (input.host ?? "").lowercased()
        let path = input.path.lowercased()

        if isGranicusHost(host) {
            // A player redesign must not make the app *less* capable than the generic
            // path every other URL already takes — fall through instead of failing.
            do {
                return try await resolveGranicus(input)
            } catch {
                downloadLog.error("Granicus scrape failed, falling back to yt-dlp: \(String(describing: error), privacy: .public)")
                return ProbeResult(
                    inputURL: input,
                    downloadURL: input,
                    refererURL: nil,
                    title: "Granicus meeting",
                    kind: "Granicus",
                    detail: "The player layout was not recognised, so yt-dlp will resolve this link directly.",
                    confidence: .unverified
                )
            }
        }

        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" {
            return ProbeResult(
                inputURL: input,
                downloadURL: input,
                refererURL: nil,
                title: "YouTube video",
                kind: "YouTube",
                detail: "yt-dlp will resolve the best available audio stream.",
                confidence: .unverified
            )
        }

        if path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".webm") || path.hasSuffix(".mp3") {
            return ProbeResult(
                inputURL: input,
                downloadURL: input,
                refererURL: nil,
                title: "Direct media URL",
                kind: "Direct media",
                detail: "The supplied media URL will be downloaded and converted to audio.",
                confidence: .unverified
            )
        }

        return ProbeResult(
            inputURL: input,
            downloadURL: input,
            refererURL: nil,
            title: "Public media URL",
            kind: "Auto-detected",
            detail: "yt-dlp will identify the public media source.",
            confidence: .unverified
        )
    }

    private func resolveGranicus(_ input: URL) async throws -> ProbeResult {
        let page = try await fetch(input)
        // Resolve relative links against the URL actually landed on, not the one
        // requested — municipal vanity URLs commonly 301 onto <city>.granicus.com.
        let playerURL = playerURLFromPage(page.html, baseURL: page.finalURL)
            ?? fallbackPlayerURL(for: page.finalURL)
            ?? page.finalURL

        let playerHTML: String
        let playerBase: URL
        if playerURL == page.finalURL {
            playerHTML = page.html
            playerBase = page.finalURL
        } else {
            guard isAllowedMediaURL(playerURL) else { throw ResolverError.noMediaFound }
            let playerPage = try await fetch(playerURL)
            playerHTML = playerPage.html
            playerBase = playerPage.finalURL
        }

        guard let sourceString = mediaSource(in: playerHTML),
              let sourceURL = normalizedURL(sourceString, baseURL: playerBase),
              isAllowedMediaURL(sourceURL) else {
            throw ResolverError.noMediaFound
        }

        let title = pageTitle(page.html)
            ?? pageTitle(playerHTML)
            ?? "Granicus public meeting"

        return ProbeResult(
            inputURL: input,
            downloadURL: sourceURL,
            refererURL: playerURL,
            title: title,
            kind: "Granicus",
            detail: "Found the public player frame and its HLS media source.",
            confidence: .confirmed
        )
    }

    private func fetch(_ url: URL) async throws -> (html: String, finalURL: URL) {
        var request = URLRequest(url: url)
        request.setValue(downloaderUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await Self.session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw ResolverError.unavailable("The public page returned HTTP \(httpResponse.statusCode).")
            }
            guard data.count <= Self.maximumPageBytes else {
                throw ResolverError.unavailable("The public page was too large to inspect.")
            }
            let body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            guard let html = body else {
                throw ResolverError.unavailable("The page response was not readable text.")
            }
            let landed = response.url ?? url
            guard isAllowedMediaURL(landed) else {
                throw ResolverError.unavailable("The page redirected somewhere the app will not follow.")
            }
            return (html, landed)
        } catch let error as ResolverError {
            throw error
        } catch {
            throw ResolverError.unavailable("Could not load the public page: \(error.localizedDescription)")
        }
    }

    private func playerURLFromPage(_ html: String, baseURL: URL) -> URL? {
        let pattern = #"<iframe[^>]+src\s*=\s*[\"']([^\"']*\/videos\/[^\"']+)[\"']"#
        guard let value = firstMatch(pattern, in: html, options: [.caseInsensitive]) else { return nil }
        return normalizedURL(value, baseURL: baseURL)
    }

    private func fallbackPlayerURL(for input: URL) -> URL? {
        guard let host = input.host,
              let components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              let clipID = components.queryItems?.first(where: { $0.name == "clip_id" })?.value,
              !clipID.isEmpty else { return nil }

        var player = URLComponents()
        player.scheme = input.scheme ?? "https"
        player.host = host
        player.path = "/videos/\(clipID)/player"
        player.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "captions", value: "false")
        ]
        return player.url
    }

    private func mediaSource(in html: String) -> String? {
        let sourcePattern = #"<(?:source|video)[^>]+(?:src|data-src)\s*=\s*[\"']([^\"']+)[\"']"#
        if let source = firstMatch(sourcePattern, in: html, options: [.caseInsensitive]) {
            return decodeHTML(source)
        }

        // Some player versions place the source inside an inline script.
        let mediaURLPattern = #"https?:\\/\\/[^\"'\s<>]+\.(?:m3u8|mp4)(?:[^\"'\s<>]*)"#
        return firstMatch(mediaURLPattern, in: html).map { decodeHTML($0).replacingOccurrences(of: "\\/", with: "/") }
    }

    private func normalizedURL(_ value: String, baseURL: URL) -> URL? {
        let decoded = decodeHTML(value).replacingOccurrences(of: "\\/", with: "/")
        if decoded.hasPrefix("//") {
            return URL(string: "https:\(decoded)")
        }
        return URL(string: decoded, relativeTo: baseURL)?.absoluteURL
    }

    private func pageTitle(_ html: String) -> String? {
        guard let title = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let cleaned = decodeHTML(title).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    /// Signed CDN URLs routinely carry `&#38;`; leaving it encoded corrupts the query
    /// and the download fails for a video that is actually available.
    private func decodeHTML(_ value: String) -> String {
        var out = value
        let entities = [
            ("&#x2F;", "/"), ("&#47;", "/"),
            ("&quot;", "\""), ("&#34;", "\""),
            ("&apos;", "'"), ("&#39;", "'"),
            ("&lt;", "<"), ("&#60;", "<"),
            ("&gt;", ">"), ("&#62;", ">"),
            ("&#38;", "&"), ("&#x26;", "&"),
            ("&amp;", "&")   // last: so &amp;#38; collapses correctly
        ]
        for (entity, replacement) in entities {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
private final class DownloaderModel: ObservableObject {
    /// Set while any window has a download in flight, so the app can warn on quit.
    static var activeDownloadCount = 0

    @Published var urlText = "" {
        didSet {
            guard urlText != oldValue else { return }
            invalidateInspectionForURLChange()
            scheduleAutoInspect()
        }
    }
    @Published var filename: String {
        didSet {
            guard !isApplyingAutomaticFilename, filename != oldValue else { return }
            hasManualFilename = true
        }
    }
    @Published var format: AudioFormat = .m4a
    @Published private(set) var probe: ProbeResult?
    @Published private(set) var isInspecting = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isConverting = false
    @Published private(set) var progress: Double?
    @Published private(set) var status = "Paste a public YouTube or meeting URL to begin."
    @Published private(set) var errorMessage: String?
    @Published private(set) var didFail = false
    @Published private(set) var lastOutputURL: URL?
    /// True once the currently inspected link has been saved, until the link
    /// changes. Drives the post-download button state: a still-prominent
    /// "Download audio" read as "not done yet" and invited a pointless re-run.
    @Published private(set) var hasSavedCurrentLink = false

    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    private var inspectionTask: Task<Void, Never>?
    private var autoInspectTask: Task<Void, Never>?
    private var inspectionToken = UUID()
    private var isApplyingAutomaticFilename = false
    private var hasManualFilename = false
    private var wasCancelled = false
    private var didFinishCurrentDownload = false
    private var observedOutputPath: String?
    private var skippedExistingFile = false
    private var stagingDirectory: URL?

    init() {
        filename = "meeting-audio-\(Self.filenameDate())"
    }

    var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var canDownload: Bool {
        probe != nil && !isInspecting && !isDownloading
    }

    // MARK: - Inspection

    func inspect() {
        guard !isDownloading else { return }
        autoInspectTask?.cancel()
        inspectionTask?.cancel()
        errorMessage = nil
        didFail = false
        probe = nil
        hasSavedCurrentLink = false

        let trimmed = sanitizeURLText(urlText)
        guard let inputURL = URL(string: trimmed),
              let scheme = inputURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              inputURL.host != nil else {
            isInspecting = false
            errorMessage = ResolverError.invalidURL.localizedDescription
            didFail = true
            status = "The URL needs attention."
            return
        }

        isInspecting = true
        status = "Inspecting public media source…"

        let token = UUID()
        inspectionToken = token

        inspectionTask = Task { [weak self] in
            // Whatever happens — success, failure, cancellation, or a URL that changed
            // underneath us — the spinner is released as long as this task still owns
            // the inspection. Previously an early return could strand it forever.
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.inspectionToken == token else { return }
                    self.isInspecting = false
                    self.inspectionTask = nil
                }
            }

            do {
                let result = try await SourceResolver().resolve(inputURL)
                try Task.checkCancellation()
                let titled = await self?.resolveTitleIfNeeded(result) ?? result
                try Task.checkCancellation()

                guard let self, self.inspectionToken == token else { return }
                probe = titled
                switch titled.confidence {
                case .confirmed:
                    status = "Found a \(titled.kind.lowercased()) media source."
                case .likely:
                    status = "Ready to download \(titled.kind.lowercased()) audio."
                case .unverified:
                    status = "Link accepted — yt-dlp will resolve it when you download."
                }
                if !hasManualFilename {
                    applyAutomaticFilename(titled.title)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.inspectionToken == token else { return }
                status = "Inspection failed."
                didFail = true
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Debounced auto-inspection. This replaces the old paste interception, so pasting,
    /// typing and dropping a URL all behave identically and Cmd-V keeps its normal
    /// insert-at-cursor semantics.
    private func scheduleAutoInspect() {
        autoInspectTask?.cancel()
        guard !isDownloading else { return }

        let candidate = sanitizeURLText(urlText)
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, host.contains("."), !host.hasSuffix(".") else { return }

        autoInspectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            guard sanitizeURLText(self.urlText) == candidate else { return }
            guard !self.isInspecting, !self.isDownloading else { return }
            self.inspect()
        }
    }

    private func invalidateInspectionForURLChange() {
        inspectionToken = UUID()          // orphan any in-flight inspection
        inspectionTask?.cancel()
        inspectionTask = nil
        probe = nil
        isInspecting = false
        // A new link deserves a fresh auto-title; this previously latched forever after
        // one manual rename and silently reused the old name for every later meeting.
        hasManualFilename = false

        guard !isDownloading else { return }   // don't stomp a running download's status
        errorMessage = nil
        didFail = false
        progress = nil
        status = sanitizeURLText(urlText).isEmpty
            ? "Paste a public YouTube or meeting URL to begin."
            : "Link changed — inspecting…"
    }

    private func resolveTitleIfNeeded(_ result: ProbeResult) async -> ProbeResult {
        let placeholderTitles = ["YouTube video", "Public media URL", "Direct media URL", "Granicus meeting"]
        guard placeholderTitles.contains(result.title),
              let ytDlpPath = Self.executable(named: "yt-dlp") else {
            return result
        }

        var arguments = [
            "--ignore-config",
            "--no-playlist",
            "--no-warnings",
            "--skip-download",
            "--socket-timeout", "15",
            "--get-title"
        ]
        if let denoPath = Self.executable(named: "deno") {
            arguments += ["--js-runtimes", "deno:\(denoPath)"]
        }
        if let refererURL = result.refererURL {
            arguments += ["--referer", refererURL.absoluteString]
        }
        var probeTarget = result.downloadURL.absoluteString
        if let adjusted = vimeoAdjustment(for: probeTarget) {
            probeTarget = adjusted.url
            arguments += adjusted.extraArguments
        }
        arguments += ["--", probeTarget]

        guard let title = await Self.runTitleProbe(executable: ytDlpPath, arguments: arguments) else {
            return result
        }

        return ProbeResult(
            inputURL: result.inputURL,
            downloadURL: result.downloadURL,
            refererURL: result.refererURL,
            title: title,
            kind: result.kind,
            detail: result.detail,
            confidence: result.confidence == .confirmed ? .confirmed : .likely
        )
    }

    /// Cancellable, deadline-bounded title probe. The old version could suspend forever:
    /// its continuation was resumed only from the termination handler, Task.cancel()
    /// could not reach it, and the spawned process was never terminated.
    private static func runTitleProbe(executable: String, arguments: [String]) async -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        let gate = ResumeGate()

        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(25))
            if task.isRunning { task.terminate() }
        }
        defer { watchdog.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                task.terminationHandler = { _ in
                    guard gate.claim() else { return }
                    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                    let value = String(data: data, encoding: .utf8)?
                        .split(whereSeparator: \.isNewline)
                        .first
                        .map(String.init)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .flatMap { $0.isEmpty ? nil : $0 }
                    continuation.resume(returning: value)
                }
                do {
                    try task.run()
                } catch {
                    if gate.claim() { continuation.resume(returning: nil) }
                }
            }
        } onCancel: {
            if task.isRunning { task.terminate() }
        }
    }

    // MARK: - Download

    func startDownload() {
        guard let probe, !isDownloading else { return }
        autoInspectTask?.cancel()
        errorMessage = nil
        didFail = false
        wasCancelled = false
        didFinishCurrentDownload = false
        observedOutputPath = nil
        skippedExistingFile = false
        hasSavedCurrentLink = false

        guard let ytDlpPath = Self.executable(named: "yt-dlp"),
              let ffmpegPath = Self.executable(named: "ffmpeg") else {
            errorMessage = "This Mac needs yt-dlp and FFmpeg. Install them with: brew install yt-dlp ffmpeg"
            didFail = true
            status = "Required command-line tools are missing."
            return
        }

        let directory = downloadsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Could not use \(directory.path): \(error.localizedDescription)"
            didFail = true
            status = "The Downloads folder is not available."
            return
        }

        // Never reuse an existing name. yt-dlp with --no-overwrites would skip the
        // download, exit 0, and the app would report a save that never happened.
        let baseName = uniqueBaseName(safeBaseName(filename), extension: format.rawValue, in: directory)
        if baseName != safeBaseName(filename) {
            isApplyingAutomaticFilename = true
            filename = baseName
            isApplyingAutomaticFilename = false
        }
        let outputURL = directory.appendingPathComponent("\(baseName).\(format.rawValue)")
        stagingDirectory = makeStagingDirectory(for: directory)

        var arguments = [
            "--ignore-config",
            "--no-playlist",
            "--newline",
            "--progress",
            "--no-overwrites",
            "--extract-audio",
            "--audio-format", format.rawValue,
            "--audio-quality", "0",
            "--socket-timeout", "30",
            "--retries", "10",
            "--fragment-retries", "10",
            // YouTube demands a "proof of origin" token for its ordinary players,
            // and no token provider ships with this app. Without one yt-dlp falls
            // back to the android_vr player, whose media URLs YouTube throttles to
            // a standstill and then refuses with HTTP 403. The embedded player
            // needs no token, so ask for it first; "default" stays on the end so
            // videos that forbid embedding still resolve the ordinary way.
            "--extractor-args", "youtube:player_client=web_embedded,default",
            "--ffmpeg-location", ffmpegPath,
            "--paths", "home:\(directory.path)",
            "--output", "\(baseName).%(ext)s"
        ]
        if let stagingDirectory {
            arguments += ["--paths", "temp:\(stagingDirectory.path)"]
        }

        // Solving those player challenges requires a JavaScript runtime. Without
        // one, yt-dlp warns and quietly falls back to formats YouTube rejects
        // with HTTP 403 — invisible on a dev Mac, where Homebrew's deno gets
        // found, and fatal on a reporter's Mac, which has no runtime at all.
        if let denoPath = Self.executable(named: "deno") {
            arguments += ["--js-runtimes", "deno:\(denoPath)"]
        }

        if let refererURL = probe.refererURL {
            arguments += ["--referer", refererURL.absoluteString]
        }
        var downloadTarget = probe.downloadURL.absoluteString
        if let adjusted = vimeoAdjustment(for: downloadTarget) {
            downloadTarget = adjusted.url
            arguments += adjusted.extraArguments
        }
        arguments += ["--", downloadTarget]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytDlpPath)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        outputPipe = pipe
        outputBuffer = ""
        process = task
        isDownloading = true
        isConverting = false
        progress = nil
        lastOutputURL = nil
        status = "Starting download…"
        Self.activeDownloadCount += 1

        downloadLog.notice("Starting yt-dlp for \(probe.downloadURL.absoluteString, privacy: .public) -> \(outputURL.path, privacy: .public)")

        do {
            try task.run()

            let readerQueue = DispatchQueue(label: "com.kevin.hearye.ytdlp-output")
            readerQueue.async { [weak self] in
                var pending = Data()
                while true {
                    // availableData, NOT readData(ofLength:) — the latter blocks until it
                    // has filled the whole buffer, so yt-dlp's small progress lines sat
                    // unread until the process exited and the bar jumped straight to 100%.
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    guard let text = decodeAvailableUTF8(&pending) else { continue }
                    Task { @MainActor [weak self] in
                        self?.consumeOutput(text)
                    }
                }

                // EOF only means the write ends closed. Reading terminationStatus before
                // Foundation has reaped the child raises an ObjC exception that Swift
                // cannot catch, so wait for the exit first.
                task.waitUntilExit()
                let exitCode = task.terminationStatus
                Task { @MainActor [weak self] in
                    self?.finishDownload(exitCode: exitCode, expected: outputURL)
                }
            }
        } catch {
            isDownloading = false
            Self.activeDownloadCount -= 1
            process = nil
            removeStagingDirectory()
            errorMessage = "Could not start yt-dlp: \(error.localizedDescription)"
            didFail = true
            status = "Download did not start."
        }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        wasCancelled = true
        process?.terminate()
        status = "Cancelling download…"
    }

    /// Called on quit so a download does not outlive the app as an orphan.
    func terminateForQuit() {
        guard isDownloading else { return }
        wasCancelled = true
        process?.terminate()
    }

    func openDownloads() {
        if let lastOutputURL, FileManager.default.fileExists(atPath: lastOutputURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: downloadsDirectory.path)
        }
    }

    private func consumeOutput(_ text: String) {
        outputBuffer += text
        let chunks = outputBuffer.components(separatedBy: .newlines)
        outputBuffer = chunks.last ?? ""
        for rawLine in chunks.dropLast() {
            consumeOutputLine(rawLine)
        }
    }

    private func consumeOutputLine(_ rawLine: String) {
        let line = rawLine.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let compact = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return }

        downloadLog.debug("\(compact, privacy: .public)")

        // Record the real path yt-dlp writes, rather than trusting the predicted one.
        // The file is built in the staging folder, so the destination of the final
        // move into Downloads is the path that counts.
        if compact.hasPrefix("[MoveFiles]"), let separator = compact.range(of: "\" to \"", options: .backwards) {
            let path = compact[separator.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !path.isEmpty { observedOutputPath = path }
        } else if let range = compact.range(of: "Destination: ") {
            let path = String(compact[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { observedOutputPath = path }
        }
        if compact.contains("has already been downloaded") || compact.contains("Cannot move file") {
            skippedExistingFile = true
        }

        if compact.contains("[ExtractAudio]") || compact.contains("Post-process") {
            isConverting = true
            progress = nil            // the bar reached 100%; conversion has no percentage
        }

        if !isConverting,
           let range = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression),
           let percent = Double(line[range].dropLast()) {
            progress = min(max(percent / 100.0, 0), 1)
        }

        if compact.contains("ERROR:") {
            errorMessage = compact
        }
        status = compact.count > 140 ? String(compact.prefix(140)) + "…" : compact
    }

    private func finishDownload(exitCode: Int32, expected: URL) {
        guard !didFinishCurrentDownload else { return }
        didFinishCurrentDownload = true

        if !outputBuffer.isEmpty {
            consumeOutputLine(outputBuffer)
            outputBuffer = ""
        }
        outputPipe = nil
        process = nil
        isDownloading = false
        isConverting = false
        Self.activeDownloadCount = max(0, Self.activeDownloadCount - 1)
        // By now a finished file has been moved out; anything left is debris.
        removeStagingDirectory()

        if wasCancelled {
            status = "Download cancelled."
            errorMessage = nil
            didFail = false
            progress = nil
            cleanUpPartialFiles(for: expected)
            return
        }

        let written = observedOutputPath.map(URL.init(fileURLWithPath:)) ?? expected
        let exists = FileManager.default.fileExists(atPath: written.path)

        if exitCode == 0 && exists && !skippedExistingFile {
            progress = 1
            lastOutputURL = written
            hasSavedCurrentLink = true
            errorMessage = nil
            didFail = false
            status = "Saved \(written.lastPathComponent) to ~/Downloads."
            downloadLog.notice("Saved \(written.path, privacy: .public)")
        } else if exitCode == 0 && (skippedExistingFile || !exists) {
            // Exit 0 is not proof anything was written.
            progress = nil
            didFail = true
            status = "Nothing was saved."
            errorMessage = skippedExistingFile
                ? "yt-dlp skipped this because a file of that name already exists. Rename the file and try again."
                : "yt-dlp reported success but no audio file was written to ~/Downloads."
            downloadLog.error("Exit 0 but no output at \(written.path, privacy: .public)")
        } else {
            progress = nil
            didFail = true
            status = "Download failed."
            if errorMessage == nil {
                errorMessage = "yt-dlp exited with status \(exitCode). Check the URL and try again."
            }
            cleanUpPartialFiles(for: expected)
        }
    }

    private func removeStagingDirectory() {
        guard let stagingDirectory else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
        self.stagingDirectory = nil
    }

    /// Remove the fragment/part debris a failed or cancelled run leaves behind
    /// when there was no staging folder and the file was built in Downloads.
    private func cleanUpPartialFiles(for expected: URL) {
        let directory = expected.deletingLastPathComponent()
        let base = expected.deletingPathExtension().lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where entry.hasPrefix(base) {
            guard entry.hasSuffix(".part") || entry.hasSuffix(".ytdl") || entry.contains(".part-Frag") else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    // MARK: - Filenames

    private func safeBaseName(_ value: String) -> String {
        sanitizedBaseName(value)
    }

    private func uniqueBaseName(_ base: String, extension ext: String, in directory: URL) -> String {
        uniqueAudioBaseName(base, extension: ext, in: directory)
    }

    private func applyAutomaticFilename(_ title: String) {
        let placeholderTitles = ["YouTube video", "Public media URL", "Direct media URL", "Granicus meeting"]
        let automaticTitle = placeholderTitles.contains(title)
            ? "meeting-audio-\(Self.filenameDate())"
            : title
        isApplyingAutomaticFilename = true
        filename = safeBaseName(automaticTitle)
        isApplyingAutomaticFilename = false
    }

    private static func executable(named name: String) -> String? {
        bundledExecutable(named: name)
    }

    private static func filenameDate() -> String {
        filenameDatestamp()
    }
}

// MARK: - Shared filename helpers
// File-scope so the headless channel watcher, which runs off the main actor,
// names its downloads exactly the way the GUI does.

private func sanitizedBaseName(_ value: String) -> String {
    let replacements = ["/", "\\", ":", "?", "%", "*", "|", "\"", "<", ">"]
    var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    for replacement in replacements {
        cleaned = cleaned.replacingOccurrences(of: replacement, with: "-")
    }
    cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    // A leading dot makes the download invisible in Finder; a trailing dot or space
    // is silently mangled by the filesystem.
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return "meeting-audio-\(filenameDatestamp())" }
    // APFS caps a path component at 255 UTF-8 bytes, and yt-dlp appends suffixes
    // like ".f140.m4a.part" — so clamp bytes, not Characters.
    return clampToBytes(cleaned, limit: 180)
}

private func clampToBytes(_ value: String, limit: Int) -> String {
    var result = value
    while result.utf8.count > limit && !result.isEmpty {
        result.removeLast()
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func uniqueAudioBaseName(_ base: String, extension ext: String, in directory: URL) -> String {
    let manager = FileManager.default
    guard manager.fileExists(atPath: directory.appendingPathComponent("\(base).\(ext)").path) else {
        return base
    }
    var index = 2
    while index < 1000 {
        let candidate = "\(base) (\(index))"
        if !manager.fileExists(atPath: directory.appendingPathComponent("\(candidate).\(ext)").path) {
            return candidate
        }
        index += 1
    }
    return "\(base)-\(filenameDatestamp())"
}

private func filenameDatestamp() -> String {
    let formatter = DateFormatter()
    // A fixed format needs a fixed locale, or a Japanese/Buddhist calendar produces
    // filenames like "meeting-audio-0008-08-11-1030".
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter.string(from: Date())
}

/// A private folder on the same volume as `destination` for yt-dlp to
/// download and convert in. MacWhisper watches ~/Downloads, and building the
/// file there let it grab the source .webm and the .m4a FFmpeg was still
/// writing; from here, yt-dlp's final move is a rename, so the audio arrives
/// whole. The folder sits in the system's temporary items, so even a killed
/// run leaves nothing in Downloads. nil means build the file in place.
private func makeStagingDirectory(for destination: URL) -> URL? {
    try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destination, create: true)
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Ask for notification permission once the app has actually finished
    /// launching — asking during view construction registered nothing with
    /// Notification Center. The outcome is written to a small support log so
    /// a silent refusal can be diagnosed without a debugger.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let line = "\(Date()): notification permission granted=\(granted) error=\(error?.localizedDescription ?? "none")\n"
            watcherLog.notice("\(line, privacy: .public)")
            let logURL = MeetingWatcher.stateDirectory.appendingPathComponent("notifications.log")
            try? FileManager.default.createDirectory(at: MeetingWatcher.stateDirectory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({ DownloaderModel.activeDownloadCount > 0 }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A download is still running."
        alert.informativeText = "Quitting now will stop it and leave the audio unfinished."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Downloading")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Channel watcher

private struct WatchedChannel: Codable, Identifiable, Equatable {
    var id: String { channelId }
    /// The human landing page for this source — what the reporter opens.
    let url: String
    /// Stable identity and `seen` key. YouTube: the UC… id. Playlist:
    /// "playlist:" plus the list id. Other kinds: a synthetic stable string.
    let channelId: String
    let title: String
    /// nil or "youtube" = a YouTube channel; "playlist" = one YouTube
    /// playlist, for a body that shares a channel with others; "podcast" =
    /// an RSS feed with audio enclosures (Granicus); "webpage" = a recordings
    /// page whose links are scraped. Optional so state files from 1.6 still
    /// decode.
    var kind: String? = nil
    /// For "podcast": the feed to poll, when it differs from the landing page.
    var feedURL: String? = nil

    var sourceKind: String { kind ?? "youtube" }

    /// Channels and playlists both yield YouTube video ids, and share the
    /// live-stream checks.
    var isYouTube: Bool { sourceKind == "youtube" || sourceKind == "playlist" }
}

/// What the watcher process is doing right now, for the window to display
/// when it happens to be open. Written by the watcher, read by the GUI.
private struct WatcherProgress: Codable {
    var phase: String        // "checking", "downloading", "converting", "idle"
    var channel: String = ""
    var title: String = ""
    var percent: Double = 0
    var updatedAt: Date = Date()
}

/// One meeting recording discovered at a source, whatever the source type.
private struct WatcherEntry {
    let id: String
    let title: String
    /// Direct or extractor-resolvable media URL; nil for YouTube entries,
    /// where the watch URL is built from the id.
    let mediaURL: String?
}

private struct WatcherState: Codable {
    var enabled = false
    var intervalMinutes = 60
    var channels: [WatchedChannel] = []
    /// channelId -> video ids already handled (downloaded, or present before
    /// watching began — the backlog is never downloaded).
    var seen: [String: [String]] = [:]
    /// videoId -> failed download attempts; three strikes ends the retries.
    var attempts: [String: Int] = [:]
    /// channelId -> when its baseline was recorded, i.e. when watching it
    /// began. Optional because a missing key would fail decoding and reset
    /// the watcher; state files from 2.0 have none.
    var watchingSince: [String: Date]?
    var lastCheck: Date?
    var lastResult: String?
}

/// The headless half of channel watching. launchd re-runs the app's own
/// binary with `--watch-run` on an interval; this reads the shared state
/// file, polls each channel's RSS feed, downloads anything new through the
/// same yt-dlp pipeline as the GUI, and posts a notification. Everything here
/// stays off the main actor: there is no UI in this process.
private enum MeetingWatcher {
    static let feedHost = "www.youtube.com"

    /// Everything the watcher touches hangs off the real home directory —
    /// modern macOS ignores a $HOME override in both NSHomeDirectory and
    /// FileManager — so tests redirect it explicitly with HEARYE_HOME.
    static var homeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["HEARYE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var stateDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/HearYe")
    }
    static var stateURL: URL { stateDirectory.appendingPathComponent("watcher.json") }

    static func loadState() -> WatcherState {
        // The decoder must match the encoder's ISO-8601 dates, or the file this
        // process wrote last cycle fails to decode and the watcher silently
        // resets to a disabled default forever.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(WatcherState.self, from: data) else {
            return WatcherState()
        }
        return state
    }

    static var progressURL: URL { stateDirectory.appendingPathComponent("watcher-progress.json") }

    static func writeProgress(_ progress: WatcherProgress) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(progress) else { return }
        try? data.write(to: progressURL, options: .atomic)
    }

    static func loadProgress() -> WatcherProgress? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: progressURL) else { return nil }
        return try? decoder.decode(WatcherProgress.self, from: data)
    }

    static func saveState(_ state: WatcherState) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Process runner

    /// Run a tool to completion, draining both pipes off-thread — yt-dlp's
    /// output would otherwise fill the pipe buffer and deadlock the child.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            return (-1, "could not start \(executable): \(error.localizedDescription)")
        }

        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Like `run`, but hands each output line to `onLine` as it arrives, so
    /// a long download can report progress instead of going dark for an hour.
    static func runStreaming(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                             onLine: @escaping (String) -> Void) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let collected = NSMutableString()
        var partial = ""
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            collected.append(chunk)
            partial += chunk
            // yt-dlp separates progress updates with \r as well as \n.
            var lines = partial.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            partial = lines.removeLast()
            lock.unlock()
            lines.filter { !$0.isEmpty }.forEach(onLine)
        }

        do {
            try task.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-1, "could not start \(executable): \(error.localizedDescription)")
        }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        task.waitUntilExit()
        watchdog.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return (task.terminationStatus, collected as String)
    }

    static func ytDlp(_ arguments: [String], timeout: TimeInterval,
                      onLine: ((String) -> Void)? = nil) -> (status: Int32, output: String)? {
        guard let ytDlpPath = bundledExecutable(named: "yt-dlp") else { return nil }
        var fullArguments = ["--ignore-config", "--no-playlist"]
        if let denoPath = bundledExecutable(named: "deno") {
            fullArguments += ["--js-runtimes", "deno:\(denoPath)"]
        }
        fullArguments += arguments
        if let onLine {
            return runStreaming(ytDlpPath, fullArguments, timeout: timeout, onLine: onLine)
        }
        return run(ytDlpPath, fullArguments, timeout: timeout)
    }

    // MARK: Channel resolution and polling

    /// Turn whatever the user pasted — @handle, channel page, /videos page,
    /// or a playlist link — into a watchable source: for a channel, the
    /// stable UC… id the RSS feed needs, plus a display name.
    static func resolveChannel(_ input: String) -> WatchedChannel? {
        var normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let listID = playlistID(in: normalized) {
            return resolvePlaylist(listID)
        }
        if normalized.hasPrefix("@") {
            normalized = "https://www.youtube.com/\(normalized)"
        }
        guard normalized.hasPrefix("http") else { return nil }
        if normalized.contains("youtube.com/"), !normalized.hasSuffix("/videos") {
            normalized += "/videos"
        }
        guard let result = ytDlp([
            "--flat-playlist", "--playlist-items", "1", "--no-warnings",
            "--socket-timeout", "20",
            "--print", "%(playlist_channel_id)s\t%(playlist_channel)s",
            "--", normalized
        ], timeout: 60), result.status == 0 else { return nil }
        let fields = result.output
            .split(whereSeparator: \.isNewline)
            .first.map { $0.split(separator: "\t", maxSplits: 1).map(String.init) } ?? []
        guard fields.count == 2, fields[0].hasPrefix("UC") else { return nil }
        return WatchedChannel(url: normalized, channelId: fields[0], title: fields[1])
    }

    /// The list id in a playlist link — /playlist?list=…, or a watch or
    /// share link that carries one. Mixes (RD…) and the personal Watch
    /// Later and Liked lists are not playlists anyone else can see.
    static func playlistID(in input: String) -> String? {
        guard let components = URLComponents(string: input),
              let host = components.host?.lowercased(),
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com"),
              let list = components.queryItems?.first(where: { $0.name == "list" })?.value,
              list.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              !list.hasPrefix("RD"), !["WL", "LL", "LM"].contains(list) else { return nil }
        return list
    }

    /// Confirm the playlist exists and is public, and name it after itself:
    /// alerts then read "New Civilian Oversight Commission meeting saved".
    static func resolvePlaylist(_ listID: String) -> WatchedChannel? {
        let url = "https://www.youtube.com/playlist?list=\(listID)"
        guard let result = ytDlp([
            "--flat-playlist", "--playlist-items", "1", "--no-warnings",
            "--socket-timeout", "20",
            "--print", "playlist:%(id)s\t%(title)s",
            "--", url
        ], timeout: 60), result.status == 0 else { return nil }
        let fields = result.output
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("\(listID)\t") }
            .map { $0.split(separator: "\t", maxSplits: 1).map(String.init) } ?? []
        guard fields.count == 2 else { return nil }
        let title = fields[1] == "NA" ? "YouTube playlist" : fields[1]
        return WatchedChannel(url: url, channelId: "playlist:\(listID)", title: title, kind: "playlist")
    }

    /// The uploads RSS feed: free, tiny, and none of the bot-detection risk
    /// of scraping the channel page. It lists the newest ~15 uploads.
    static func fetchFeedVideoIDs(channelId: String) async -> [WatcherEntry]? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = feedHost
        components.path = "/feeds/videos.xml"
        components.queryItems = [URLQueryItem(name: "channel_id", value: channelId)]
        guard let url = components.url else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return FeedParser().parse(data)?.map { WatcherEntry(id: $0.id, title: $0.title, mediaURL: nil) }
    }

    /// A podcast RSS feed with audio enclosures — Granicus publishes one per
    /// meeting body, which sidesteps its collapsible archive page entirely.
    static func fetchPodcastEntries(feedURL: String) async -> [WatcherEntry]? {
        guard let url = URL(string: feedURL),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let items = PodcastParser().parse(data)
        guard let items, !items.isEmpty else { return nil }
        return items.map { WatcherEntry(id: $0.enclosure, title: $0.title, mediaURL: $0.enclosure) }
    }

    /// A recordings webpage (Finalsite and the like): pull every anchor whose
    /// target looks like a meeting recording — direct audio/video files
    /// (including Finalsite's extensionless /fs/resource-manager/view/ links,
    /// which redirect to the file), Zoom cloud recordings, Vimeo — and use
    /// the link's own label as the title.
    static func fetchWebpageEntries(pageURL: String) async -> [WatcherEntry]? {
        guard let baseURL = URL(string: pageURL) else { return nil }
        var request = URLRequest(url: baseURL)
        request.setValue(downloaderUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fullHTML = String(data: data, encoding: .utf8) else { return nil }

        // Read only the page's main content: site menus repeat on every page
        // and carry stray videos (RUSD's nav links a student-technology
        // video on Vimeo) that are not meetings.
        var html = fullHTML
        if let mainStart = fullHTML.range(of: "<main", options: .caseInsensitive) {
            let tail = fullHTML[mainStart.lowerBound...]
            let mainEnd = tail.range(of: "</main>", options: .caseInsensitive)?.upperBound ?? tail.endIndex
            html = String(tail[..<mainEnd])
        }

        func decodeEntities(_ value: String) -> String {
            value.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
        }

        func isMediaFilename(_ name: String) -> Bool {
            let path = (name.split(separator: "?").first.map(String.init) ?? name).lowercased()
            return [".mp3", ".m4a", ".mp4", ".m4v", ".mov", ".wav"].contains { path.hasSuffix($0) }
        }

        // Finalsite names the file behind a resource-manager link only in
        // data-file-name; the same links also serve agenda PDFs.
        func isRecordingLink(_ href: String, anchor: String) -> Bool {
            if href.contains("zoom.us/rec/") { return true }
            if href.range(of: #"vimeo\.com/\d+"#, options: .regularExpression) != nil { return true }
            if let nameRange = anchor.range(of: #"data-file-name="[^"]+""#, options: .regularExpression),
               isMediaFilename(String(anchor[nameRange].dropFirst(#"data-file-name=""#.count).dropLast())) {
                return true
            }
            return isMediaFilename(href)
        }

        guard let anchorRegex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }

        var entries: [WatcherEntry] = []
        var seenHrefs = Set<String>()
        let range = NSRange(html.startIndex..., in: html)
        anchorRegex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { return }
            let anchor = String(html[Range(match.range(at: 0), in: html)!])
            let rawHref = decodeEntities(String(html[hrefRange]))
            guard isRecordingLink(rawHref, anchor: anchor) else { return }
            // Finalsite links are site-relative; download needs the full URL.
            let href = URL(string: rawHref, relativeTo: baseURL)?.absoluteString ?? rawHref
            guard !seenHrefs.contains(href) else { return }
            seenHrefs.insert(href)

            // The visible label wins over the title attribute: RUSD copies
            // links forward and leaves stale titles behind (its Aug. 18
            // recording carried the June 8 title).
            func clean(_ value: String) -> String {
                decodeEntities(value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .replacingOccurrences(of: "(opens in new window/tab)", with: "")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var title = clean(String(html[bodyRange]))
            if title.isEmpty,
               let titleMatch = anchor.range(of: #"title="([^"]+)""#, options: .regularExpression) {
                title = clean(String(anchor[titleMatch]).dropFirst(#"title=""#.count).dropLast(1).description)
            }
            if title.isEmpty { title = "Meeting recording \(filenameDatestamp())" }
            entries.append(WatcherEntry(id: href, title: title, mediaURL: href))
        }
        return entries.isEmpty ? nil : entries
    }

    private final class PodcastParser: NSObject, XMLParserDelegate {
        private var items: [(title: String, enclosure: String)] = []
        private var inItem = false
        private var currentElement = ""
        private var currentTitle = ""
        private var currentEnclosure = ""

        func parse(_ data: Data) -> [(title: String, enclosure: String)]? {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() else { return nil }
            return items
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            currentElement = name
            if name == "item" {
                inItem = true
                currentTitle = ""
                currentEnclosure = ""
            }
            if inItem, name == "enclosure", let url = attributes["url"] {
                currentEnclosure = url
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inItem, currentElement == "title" else { return }
            currentTitle += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            currentElement = ""
            if name == "item" {
                inItem = false
                let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentEnclosure.isEmpty {
                    items.append((title.isEmpty ? "Meeting recording" : title, currentEnclosure))
                }
            }
        }
    }

    /// When the RSS feed is down — YouTube intermittently serves it errors —
    /// list the channel's newest uploads through yt-dlp instead. Heavier, so
    /// it is only the fallback, but it keeps the watcher alive through feed
    /// outages and would survive the feed being retired outright.
    static func fetchLatestViaYtDlp(url: String) -> [WatcherEntry]? {
        guard let result = ytDlp([
            "--flat-playlist", "--playlist-items", "1-15", "--no-warnings",
            "--socket-timeout", "20",
            "--print", "%(id)s\t%(title)s",
            "--", url
        ], timeout: 180), result.status == 0 else { return nil }
        let entries = result.output.split(whereSeparator: \.isNewline).compactMap { line -> WatcherEntry? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return WatcherEntry(id: parts[0], title: parts[1], mediaURL: nil)
        }
        return entries.isEmpty ? nil : entries
    }

    /// Every video in a playlist. A playlist runs in its owner's order, and
    /// one that files new meetings at the bottom would hide them from any
    /// newest-N listing, so the whole list is read each time — one request
    /// per hundred videos. Private and deleted placeholders are left out,
    /// so a video that is later made public still counts as new. An empty
    /// list is a real answer: a fresh playlist's first meeting must not
    /// vanish into the baseline.
    static func fetchPlaylistEntries(url: String) -> [WatcherEntry]? {
        guard let result = ytDlp([
            "--flat-playlist", "--no-warnings",
            "--socket-timeout", "20",
            "--print", "%(id)s\t%(title)s",
            "--", url
        ], timeout: 600), result.status == 0 else { return nil }
        let placeholders: Set<String> = ["[Private video]", "[Deleted video]"]
        return result.output.split(whereSeparator: \.isNewline).compactMap { line -> WatcherEntry? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !placeholders.contains(parts[1]) else { return nil }
            return WatcherEntry(id: parts[0], title: parts[1], mediaURL: nil)
        }
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        private var entries: [(id: String, title: String)] = []
        private var inEntry = false
        private var currentElement = ""
        private var currentID = ""
        private var currentTitle = ""

        func parse(_ data: Data) -> [(id: String, title: String)]? {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() else { return nil }
            return entries
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            currentElement = name
            if name == "entry" {
                inEntry = true
                currentID = ""
                currentTitle = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inEntry else { return }
            if currentElement == "yt:videoId" { currentID += string }
            if currentElement == "title" { currentTitle += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            currentElement = ""
            if name == "entry" {
                inEntry = false
                let id = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty {
                    entries.append((id, currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    // MARK: Downloading

    /// A meeting shows up in the feed the moment the stream is scheduled.
    /// Only a finished recording is worth fetching; anything still upcoming,
    /// live, or freshly ended stays unseen and is retried next cycle. The
    /// publish time comes from the same lookup, for the playlist backlog
    /// check; nil when YouTube does not say.
    static func videoStatus(videoId: String) -> (liveStatus: String, published: Date?)? {
        guard let result = ytDlp([
            "--no-warnings", "--skip-download", "--socket-timeout", "20",
            "--print", "%(live_status)s\t%(timestamp)s",
            "--", "https://www.youtube.com/watch?v=\(videoId)"
        ], timeout: 90), result.status == 0,
              let line = result.output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(separator: "\t").map(String.init)
        let published = fields.count > 1 ? Double(fields[1]).map(Date.init(timeIntervalSince1970:)) : nil
        return (fields[0], published)
    }

    static func downloadAudio(mediaURL: String, title: String, channelTitle: String) -> Bool {
        guard let ffmpegPath = bundledExecutable(named: "ffmpeg") else { return false }
        let downloads = homeDirectory.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let base = uniqueAudioBaseName(sanitizedBaseName(title), extension: "m4a", in: downloads)
        let outputURL = downloads.appendingPathComponent("\(base).m4a")

        var targetURL = mediaURL
        var extraArguments: [String] = []
        if let adjusted = vimeoAdjustment(for: mediaURL) {
            targetURL = adjusted.url
            extraArguments = adjusted.extraArguments
        }

        // Report which meeting is being fetched and how far along it is; the
        // window shows this when it happens to be open.
        var progress = WatcherProgress(phase: "downloading", channel: channelTitle, title: title)
        writeProgress(progress)
        let percentRegex = try? NSRegularExpression(pattern: #"\[download\]\s+([\d.]+)%"#)
        var lastWritten = -1.0
        let onLine: (String) -> Void = { line in
            if let percentRegex,
               let match = percentRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line),
               let percent = Double(line[range]) {
                if percent - lastWritten >= 1 || percent >= 100 {
                    lastWritten = percent
                    progress.phase = "downloading"
                    progress.percent = percent
                    progress.updatedAt = Date()
                    writeProgress(progress)
                }
            } else if line.hasPrefix("[ExtractAudio]") {
                progress.phase = "converting"
                progress.percent = 100
                progress.updatedAt = Date()
                writeProgress(progress)
            }
        }

        // Mirrors the GUI's download pipeline: m4a, built in a staging folder
        // and moved into Downloads finished, embedded-player client, bundled
        // JS runtime. The youtube: extractor argument is scoped, so Zoom,
        // Vimeo, Granicus, and direct files pass through yt-dlp's ordinary
        // handling.
        let staging = makeStagingDirectory(for: downloads)
        defer {
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
        var pathArguments = ["--paths", "home:\(downloads.path)"]
        if let staging {
            pathArguments += ["--paths", "temp:\(staging.path)"]
        }
        let result = ytDlp([
            "--newline", "--no-overwrites",
            "--extract-audio", "--audio-format", "m4a", "--audio-quality", "0",
            "--socket-timeout", "30", "--retries", "10", "--fragment-retries", "10",
            "--extractor-args", "youtube:player_client=web_embedded,default",
            "--ffmpeg-location", ffmpegPath,
        ] + pathArguments + [
            "--output", "\(base).%(ext)s",
        ] + extraArguments + ["--", targetURL], timeout: 3 * 3600, onLine: onLine)

        guard let result, result.status == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            watcherLog.error("Watcher download failed for \(mediaURL, privacy: .public): \(result?.output.suffix(300) ?? "yt-dlp missing", privacy: .public)")
            return false
        }
        watcherLog.notice("Watcher saved \(outputURL.lastPathComponent, privacy: .public) for \(channelTitle, privacy: .public)")
        return true
    }

    // MARK: Alerts

    /// A native notification with the app's icon. Info.plist declares
    /// NSUserNotificationAlertStyle "alert", so once the reporter grants
    /// permission these default to the persistent style — on screen until
    /// dismissed, not a banner that slides away while nobody is at the desk.
    static func alert(title: String, body: String) async {
        // Notification Center only accepts posts from an instance of the app
        // that LaunchServices launched — not from this launchd-run watcher
        // process. So hand the alert to a fresh, launched instance, which
        // posts it natively (HearYe icon, persistent alert style) and exits.
        if let bundleID = Bundle.main.bundleIdentifier {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", "-b", bundleID, "--args", "--alert", title, body]
            if (try? open.run()) != nil {
                open.waitUntilExit()
                if open.terminationStatus == 0 { return }
            }
        }
        // No launchable bundle — show the dialog from here instead.
        showIconDialog(title: title, body: body)
    }

    /// A dialog carrying the app's own icon that stays until dismissed. Used
    /// wherever Notification Center is unavailable. Not waited on: the
    /// osascript process lives exactly as long as the dialog does.
    static func showIconDialog(title: String, body: String) {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var script = "display dialog \"\(escaped(body))\" with title \"\(escaped(title))\" buttons {\"OK\"} default button \"OK\""
        if let icon = Bundle.main.url(forResource: "HearYe", withExtension: "icns") {
            script += " with icon POSIX file \"\(escaped(icon.path))\""
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    // MARK: One polling cycle

    /// `force` is the Check Now button: run for the ticked channels even
    /// while scheduled watching is switched off.
    static func runOnce(force: Bool = false) async {
        var state = loadState()
        guard state.enabled || force, !state.channels.isEmpty else {
            watcherLog.notice("Watcher ran with nothing to do (disabled or no channels).")
            return
        }

        writeProgress(WatcherProgress(phase: "checking"))
        defer { writeProgress(WatcherProgress(phase: "idle")) }

        var summary: [String] = []
        for channel in state.channels {
            var fetched: [WatcherEntry]?
            switch channel.sourceKind {
            case "podcast":
                fetched = await fetchPodcastEntries(feedURL: channel.feedURL ?? channel.url)
            case "webpage":
                fetched = await fetchWebpageEntries(pageURL: channel.url)
            case "playlist":
                fetched = fetchPlaylistEntries(url: channel.url)
            default:
                fetched = await fetchFeedVideoIDs(channelId: channel.channelId)
                if fetched == nil {
                    fetched = fetchLatestViaYtDlp(url: channel.url)
                }
            }
            guard let entries = fetched else {
                summary.append("\(channel.title): feed unavailable")
                continue
            }

            // First sight of a channel records the backlog without fetching
            // it — watching starts at "now", not at 15 old meetings.
            guard var seenIDs = state.seen[channel.channelId] else {
                state.seen[channel.channelId] = entries.map(\.id)
                var since = state.watchingSince ?? [:]
                since[channel.channelId] = Date()
                state.watchingSince = since
                summary.append("\(channel.title): baseline of \(entries.count) recorded")
                continue
            }

            let seenSet = Set(seenIDs)
            let fresh = entries.filter { !seenSet.contains($0.id) }.reversed()  // oldest first
            var savedCount = 0
            var backlogCount = 0
            for entry in fresh {
                var canDownload = true
                if channel.isYouTube {
                    // A YouTube meeting shows up the moment the stream is
                    // scheduled; only a finished recording is worth fetching.
                    let status = videoStatus(videoId: entry.id)
                    switch status?.liveStatus {
                    case "is_upcoming", "is_live", "post_live":
                        continue  // next cycle gets it
                    case nil:
                        canDownload = false
                    default:
                        break
                    }
                    // A playlist can be handed old meetings at any time — a
                    // clerk filing last year's recordings would otherwise
                    // queue every one. Anything published more than a week
                    // before watching began is backlog, left alone like the
                    // baseline. The week covers a recording posted just before
                    // watching began that reached the playlist just after.
                    if channel.sourceKind == "playlist",
                       let published = status?.published,
                       let since = state.watchingSince?[channel.channelId],
                       published < since.addingTimeInterval(-7 * 24 * 3600) {
                        seenIDs.append(entry.id)
                        backlogCount += 1
                        continue
                    }
                }
                let mediaURL = entry.mediaURL ?? "https://www.youtube.com/watch?v=\(entry.id)"
                if canDownload, downloadAudio(mediaURL: mediaURL, title: entry.title, channelTitle: channel.title) {
                    seenIDs.append(entry.id)
                    state.attempts.removeValue(forKey: entry.id)
                    savedCount += 1
                    await alert(
                        title: "New \(channel.title) meeting saved",
                        body: "\(entry.title) — audio is in your Downloads folder."
                    )
                    continue
                }
                state.attempts[entry.id, default: 0] += 1
                if state.attempts[entry.id, default: 0] >= 3 {
                    seenIDs.append(entry.id)  // stop retrying
                    state.attempts.removeValue(forKey: entry.id)
                    await alert(
                        title: "Couldn't fetch a \(channel.title) meeting",
                        body: "\(entry.title) failed three times. Fetch it by hand from the meetings page."
                    )
                }
            }

            // Never forget anything the source still lists — a playlist is
            // read whole, so a flat cap would drop part of it and re-examine
            // those videos every cycle — plus the 200 most recent that have
            // left the listing, in case one returns to it.
            let listed = Set(entries.map(\.id))
            state.seen[channel.channelId] = Array(seenIDs.filter { !listed.contains($0) }.suffix(200))
                + seenIDs.filter { listed.contains($0) }
            var line = "\(channel.title): \(savedCount) saved, \(fresh.count - savedCount - backlogCount) pending"
            if backlogCount > 0 {
                line += ", \(backlogCount) older skipped"
            }
            summary.append(line)
        }

        state.lastCheck = Date()
        state.lastResult = summary.joined(separator: "; ")
        saveState(state)
        watcherLog.notice("Watcher cycle: \(state.lastResult ?? "", privacy: .public)")
    }
}

/// Installs and removes the launchd job that re-runs this app headlessly.
/// A LaunchAgent survives app quit, logout, and reboot — that is what makes
/// this a watcher rather than a timer that dies with the window.
private enum WatcherAgent {
    static let label = "com.kevin.hearye.watcher"

    static var plistURL: URL {
        MeetingWatcher.homeDirectory.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func install(intervalMinutes: Int) throws {
        guard let executable = Bundle.main.executablePath else {
            throw NSError(domain: "HearYe", code: 1, userInfo: [NSLocalizedDescriptionKey: "The app bundle has no executable path."])
        }
        let logPath = MeetingWatcher.homeDirectory
            .appendingPathComponent("Library/Logs/HearYe-watcher.log").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--watch-run"],
            "StartInterval": max(5, intervalMinutes) * 60,
            // Fixed morning sweep, local time, on top of whatever interval the
            // reporter picked: overnight postings are on disk before the
            // workday starts. Not surfaced in the UI by design.
            "StartCalendarInterval": [
                ["Hour": 9, "Minute": 0],
                ["Hour": 9, "Minute": 30],
                ["Hour": 10, "Minute": 0]
            ],
            "RunAtLoad": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath
        ]
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // Re-bootstrap so an interval or app-path change takes effect now.
        _ = MeetingWatcher.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20)
        let result = MeetingWatcher.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path], timeout: 20)
        guard result.status == 0 else {
            throw NSError(domain: "HearYe", code: 2, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(result.output)"])
        }
    }

    /// True when the installed job no longer matches this app: a different
    /// executable path (the app was moved or upgraded), a missing morning
    /// sweep, or a different interval. An upgrade that left the old path in
    /// place made launchd fail every scheduled run with EX_CONFIG.
    static func isStale(intervalMinutes: Int) -> Bool {
        guard let executable = Bundle.main.executablePath,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.first == executable,
              plist["StartCalendarInterval"] != nil,
              (plist["StartInterval"] as? Int) == max(5, intervalMinutes) * 60 else {
            return true
        }
        return false
    }

    static func uninstall() {
        _ = MeetingWatcher.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20)
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func isLoaded() -> Bool {
        MeetingWatcher.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 20).status == 0
    }
}

@MainActor
private final class WatcherModel: ObservableObject {
    /// The Ark's home-beat meeting sources ship as ready-made selectors —
    /// identities pre-resolved, so ticking one needs no network lookup.
    /// None is watched until a reporter ticks it.
    static let presetChannels: [WatchedChannel] = [
        WatchedChannel(
            url: "https://www.youtube.com/@townoftiburon1964/videos",
            channelId: "UCm1Qh2lMsMcvDt3QiXKrf6g",
            title: "Town of Tiburon"),
        WatchedChannel(
            url: "https://www.youtube.com/@CityofBelvedere/videos",
            channelId: "UCSSPUdGTgxXb_v6Im5q0lEA",
            title: "City of Belvedere"),
        WatchedChannel(
            url: "https://www.reedschools.org/school-board/meeting-recordings",
            channelId: "webpage:reedschools-board",
            title: "Reed Union School District",
            kind: "webpage"),
        WatchedChannel(
            url: "https://www.marincounty.gov/departments/board/board-supervisors-meetings",
            channelId: "podcast:marin-bos",
            title: "Marin County Board of Supervisors",
            kind: "podcast",
            feedURL: "https://marin.granicus.com/Podcast.php?view_id=33")
    ]

    @Published private(set) var state: WatcherState
    @Published var newChannelText = ""

    init() {
        var loaded = MeetingWatcher.loadState()
        // Snap an interval from an older build onto the current choices.
        if ![60, 360, 720, 1440].contains(loaded.intervalMinutes) {
            loaded.intervalMinutes = 60
        }
        state = loaded
        // Self-heal the scheduled job: after an upgrade or a move, the job
        // launchd holds can point at an executable that no longer exists.
        // Only rewrite when something actually differs — re-bootstrapping
        // would kill a download the scheduler has in progress.
        if loaded.enabled, WatcherAgent.isStale(intervalMinutes: loaded.intervalMinutes) {
            do {
                try WatcherAgent.install(intervalMinutes: loaded.intervalMinutes)
                watcherLog.notice("Refreshed the stale watcher agent on launch.")
            } catch {
                watcherLog.error("Could not refresh the watcher agent: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Poll the watcher's progress file while the window is open. A stale
        // file (the watcher died mid-download) is treated as idle.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let latest = MeetingWatcher.loadProgress()
                let live = latest.flatMap { p -> WatcherProgress? in
                    p.phase == "idle" || Date().timeIntervalSince(p.updatedAt) > 600 ? nil : p
                }
                if live?.phase != self.progress?.phase || live?.percent != self.progress?.percent
                    || live?.title != self.progress?.title {
                    self.progress = live
                }
            }
        }
    }
    @Published private(set) var isResolving = false
    @Published private(set) var isChecking = false
    /// Live view of what the watcher process is doing, whether it was started
    /// by Check now or by the schedule; nil when nothing is happening.
    @Published private(set) var progress: WatcherProgress?
    @Published private(set) var noticeText: String?
    @Published private(set) var noticeIsError = false

    var enabledBinding: Binding<Bool> {
        Binding(get: { self.state.enabled }, set: { self.setEnabled($0) })
    }

    var intervalBinding: Binding<Int> {
        Binding(get: { self.state.intervalMinutes }, set: { self.setInterval($0) })
    }

    /// Channels typed in by the reporter, as opposed to the built-in selectors.
    var customChannels: [WatchedChannel] {
        state.channels.filter { channel in
            !Self.presetChannels.contains { $0.channelId == channel.channelId }
        }
    }

    func presetBinding(_ preset: WatchedChannel) -> Binding<Bool> {
        Binding(
            get: { self.state.channels.contains { $0.channelId == preset.channelId } },
            set: { watched in
                if watched {
                    guard !self.state.channels.contains(where: { $0.channelId == preset.channelId }) else { return }
                    self.state.channels.append(preset)
                    self.persist()
                    self.notice("Watching \(preset.title). Existing videos stay put; only meetings posted from now on are fetched.", isError: false)
                } else {
                    self.removeChannel(preset)
                }
            }
        )
    }

    func addChannel() {
        let input = newChannelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isResolving else { return }
        isResolving = true
        noticeText = nil
        Task {
            let resolved = await Task.detached { MeetingWatcher.resolveChannel(input) }.value
            self.isResolving = false
            guard let resolved else {
                self.notice("That doesn't look like a public YouTube channel or playlist. Paste a channel link like https://www.youtube.com/@townoftiburon1964/videos, or a playlist link like https://www.youtube.com/playlist?list=….", isError: true)
                return
            }
            guard !self.state.channels.contains(where: { $0.channelId == resolved.channelId }) else {
                self.notice("\(resolved.title) is already being watched.", isError: false)
                return
            }
            self.state.channels.append(resolved)
            self.newChannelText = ""
            self.persist()
            self.notice("Watching \(resolved.title). Existing videos stay put; only meetings posted from now on are fetched.", isError: false)
        }
    }

    /// Check the ticked channels right now, watching on or off. The work runs
    /// in a separate launched instance — the same headless mode the scheduler
    /// uses — so a long download survives closing this window, and alerts are
    /// attributed to the app. The window polls the state file for the result.
    func checkNow() {
        guard !isChecking, !state.channels.isEmpty,
              let bundleID = Bundle.main.bundleIdentifier else {
            if state.channels.isEmpty { notice("Tick a channel first.", isError: true) }
            return
        }
        persist()
        let startedAt = Date()
        isChecking = true
        notice("Checking now…", isError: false)

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-b", bundleID, "--args", "--watch-run", "--force"]
        do {
            try open.run()
        } catch {
            isChecking = false
            notice("Could not start the check: \(error.localizedDescription)", isError: true)
            return
        }

        Task { [weak self] in
            // A six-hour meeting can take a while to fetch; give up polling
            // after three hours and let the next launch pick up the result.
            let deadline = Date().addingTimeInterval(3 * 3600)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let latest = MeetingWatcher.loadState()
                if let lastCheck = latest.lastCheck, lastCheck > startedAt {
                    self.state = latest
                    self.isChecking = false
                    self.notice(latest.lastResult ?? "Check finished.", isError: false)
                    return
                }
            }
            self?.isChecking = false
        }
    }

    func removeChannel(_ channel: WatchedChannel) {
        state.channels.removeAll { $0.channelId == channel.channelId }
        state.seen.removeValue(forKey: channel.channelId)
        persist()
        if state.channels.isEmpty && state.enabled {
            setEnabled(false)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !state.channels.isEmpty else {
                notice("Add a channel first.", isError: true)
                return
            }
            state.enabled = true
            persist()
            // Ask now, in the GUI, so the background watcher can deliver
            // native alerts later; the Info.plist alert style makes them
            // stick until dismissed by default.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            do {
                try WatcherAgent.install(intervalMinutes: state.intervalMinutes)
                notice("Watching runs in the background even after you quit HearYe.", isError: false)
            } catch {
                state.enabled = false
                persist()
                notice("Could not start the watcher: \(error.localizedDescription)", isError: true)
            }
        } else {
            state.enabled = false
            persist()
            WatcherAgent.uninstall()
            notice("Watching stopped.", isError: false)
        }
    }

    private func setInterval(_ minutes: Int) {
        state.intervalMinutes = minutes
        persist()
        if state.enabled {
            try? WatcherAgent.install(intervalMinutes: minutes)
        }
    }

    /// The daemon appends to `seen` between GUI launches; merge before
    /// writing so a settings change can't erase what it already fetched.
    private func persist() {
        var merged = MeetingWatcher.loadState()
        merged.enabled = state.enabled
        merged.intervalMinutes = state.intervalMinutes
        merged.channels = state.channels
        merged.seen = merged.seen.filter { key, _ in state.channels.contains { $0.channelId == key } }
        merged.watchingSince = merged.watchingSince?.filter { key, _ in state.channels.contains { $0.channelId == key } }
        MeetingWatcher.saveState(merged)
        state = merged
    }

    private func notice(_ text: String, isError: Bool) {
        noticeText = text
        noticeIsError = isError
    }
}

private struct WatcherSectionView: View {
    @ObservedObject var model: WatcherModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Watch my selected channels for new meetings", isOn: model.enabledBinding)
                    .font(.headline)
                Text("Tick the channels for your beat, or add another below; nothing is watched until this is turned on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(WatcherModel.presetChannels) { preset in
                        HStack(alignment: .center, spacing: 8) {
                            Toggle("", isOn: model.presetBinding(preset))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .accessibilityLabel("Watch \(preset.title)")
                            // The name opens the body's own meetings page, so a
                            // reporter can eyeball what has been posted.
                            if let landing = URL(string: preset.url) {
                                Link(preset.title, destination: landing)
                                    .font(.subheadline)
                            } else {
                                Text(preset.title).font(.subheadline)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                ForEach(model.customChannels) { channel in
                    HStack {
                        Image(systemName: channel.sourceKind == "playlist" ? "list.and.film" : "dot.radiowaves.left.and.right")
                            .foregroundStyle(model.state.enabled ? Color.green : Color.secondary)
                            .accessibilityLabel(channel.sourceKind == "playlist" ? "Playlist" : "Channel")
                        if let landing = URL(string: channel.url) {
                            Link(channel.title, destination: landing)
                                .font(.subheadline)
                        } else {
                            Text(channel.title).font(.subheadline)
                        }
                        Spacer()
                        Button("Remove") { model.removeChannel(channel) }
                            .controlSize(.small)
                    }
                }

                HStack {
                    TextField("Paste another YouTube channel or playlist link", text: $model.newChannelText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addChannel() }
                        .accessibilityLabel("Channel or playlist to watch")
                    if model.isResolving {
                        ProgressView().controlSize(.small)
                    }
                    Button("Add") { model.addChannel() }
                        .disabled(model.isResolving || model.newChannelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("A channel's Videos page, like https://www.youtube.com/@ChannelName/videos — or a playlist, like https://www.youtube.com/playlist?list=…, to follow one board on a channel shared by many.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack {
                    Picker("Check every", selection: model.intervalBinding) {
                        Text("hour").tag(60)
                        Text("6 hours").tag(360)
                        Text("12 hours").tag(720)
                        Text("day").tag(1440)
                    }
                    .frame(width: 220)
                    Spacer()
                    if let lastCheck = model.state.lastCheck {
                        Text("Last check: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    // Works with watching on or off: it checks whatever is
                    // ticked, right now.
                    Button(model.isChecking ? "Checking…" : "Check now") { model.checkNow() }
                        .disabled(model.isChecking || model.state.channels.isEmpty)
                }

                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        switch progress.phase {
                        case "downloading", "converting":
                            Label("New meeting found: \(progress.title)", systemImage: "sparkles")
                                .font(.subheadline)
                            Text(progress.channel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if progress.phase == "converting" {
                                ProgressView()
                                Text("Converting audio…").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ProgressView(value: progress.percent, total: 100)
                                Text("Downloading \(Int(progress.percent))%").font(.caption).foregroundStyle(.secondary)
                            }
                        default:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking channels for new meetings…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let noticeText = model.noticeText {
                    Text(noticeText)
                        .font(.caption)
                        .foregroundStyle(model.noticeIsError ? Color.red : Color.secondary)
                }

                Text("New meetings are saved to ~/Downloads as m4a audio, with a notification that stays on screen until you dismiss it — click Allow when HearYe first asks to send notifications. Streams are fetched once the recording is finished; videos posted before you started watching are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }
}

private struct ContentView: View {
    @StateObject private var model = DownloaderModel()
    @StateObject private var watcherModel = WatcherModel()
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Public Media URL (YouTube, Granicus)")
                        .font(.headline)
                    TextField("https://www.youtube.com/watch?v=… or a Granicus meeting URL", text: $model.urlText)
                        .textFieldStyle(.roundedBorder)
                        .focused($urlFieldFocused)
                        .disabled(model.isDownloading)
                        .onSubmit { submitFromURLField() }
                        .accessibilityLabel("Public media URL")

                    HStack {
                        Button("Inspect link") { model.inspect() }
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(model.isInspecting || model.isDownloading || model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if model.isInspecting {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer()
                        Text("Links are inspected automatically as you paste or type.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            // Dropping a link from Safari or Mail now works the same as pasting one.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !model.isDownloading else { return false }
                model.urlText = url.absoluteString
                return true
            }

            if let probe = model.probe {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(probe.title, systemImage: probe.confidence.systemImage)
                            .font(.headline)
                            .foregroundStyle(probe.confidence.tint)
                        Text("Source: \(probe.kind) — \(probe.detail)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Media source: \(probe.downloadURL.absoluteString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(4)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Audio output")
                        .font(.headline)
                    HStack {
                        TextField("Filename (defaults to media title)", text: $model.filename)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isDownloading)
                            .accessibilityLabel("Output filename")
                        Picker("Format", selection: $model.format) {
                            ForEach(AudioFormat.allCases) { format in
                                Text(format.label).tag(format)
                            }
                        }
                        .frame(width: 240)
                        .disabled(model.isDownloading)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                        Text("Always saved to ~/Downloads")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(model.lastOutputURL == nil ? "Open Downloads" : "Reveal in Finder") {
                            model.openDownloads()
                        }
                    }
                }
                .padding(4)
            }

            WatcherSectionView(model: watcherModel)

            VStack(alignment: .leading, spacing: 8) {
                if let progress = model.progress {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.isConverting {
                    ProgressView()
                    Text("Converting audio — this can take several minutes for a long meeting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.isDownloading {
                    ProgressView()
                }

                HStack {
                    Text(model.status)
                        .font(.subheadline)
                        .foregroundStyle(model.didFail ? Color.red : Color.secondary)
                        .lineLimit(2)
                    Spacer()
                    if model.isDownloading {
                        Button("Cancel") { model.cancelDownload() }
                    } else if model.hasSavedCurrentLink {
                        // The saved file is the payoff now; a re-download is the
                        // rare case and gets the quiet button.
                        Button("Download again") { model.startDownload() }
                            .disabled(!model.canDownload)
                        Button("Reveal in Finder") { model.openDownloads() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Download audio") { model.startDownload() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canDownload)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Divider()
            Label("Use only public media you are allowed to download and transcribe. The app has no built-in duration limit; availability and provider terms still apply.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        // Scrollable, with a modest minimum: the window opens at content
        // height where the screen allows, and on a smaller display it can be
        // shrunk to fit above the Dock and scrolled instead of overflowing.
        .frame(minWidth: 720)
        .modifier(ScrollingContent())
        .onAppear { urlFieldFocused = true }
    }

    /// Wraps the page in a vertical scroller that still reports the content's
    /// own height as its ideal size, so the window opens content-sized.
    private struct ScrollingContent: ViewModifier {
        func body(content: Content) -> some View {
            ScrollView(.vertical) {
                content.fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 560)
        }
    }

    /// Return starts the download once a link has been inspected, instead of
    /// re-inspecting it and throwing the result away.
    private func submitFromURLField() {
        if model.hasSavedCurrentLink {
            // Return after a save shows the file rather than silently
            // downloading the same link twice.
            model.openDownloads()
        } else if model.canDownload {
            model.startDownload()
        } else {
            model.inspect()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HearYe")
                    .font(.system(size: 26, weight: .bold))
                Text("Public meetings, preserved.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
        }
    }
}

@main
private enum HearYeMain {
    /// launchd re-runs this same binary with `--watch-run` to poll watched
    /// channels headlessly; every other launch is the ordinary GUI app.
    static func main() async {
        if CommandLine.arguments.contains("--watch-run") {
            await MeetingWatcher.runOnce(force: CommandLine.arguments.contains("--force"))
            return
        }
        // The watcher hands alerts to a LaunchServices-launched instance of the
        // app (`open -n -b com.kevin.hearye --args --alert <title> <body>`), the
        // only context Notification Center accepts posts from. Post and exit.
        if let index = CommandLine.arguments.firstIndex(of: "--alert"),
           CommandLine.arguments.count > index + 2 {
            let title = CommandLine.arguments[index + 1]
            let body = CommandLine.arguments[index + 2]
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                // First alert on a fresh Mac: this is where the permission
                // prompt appears, so the reporter can grant it in context.
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            if status == .authorized {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                if (try? await center.add(request)) != nil { return }
            }
            // Not permitted (a managed Mac can refuse outright, and the daemon
            // then drops posts silently): a dialog with the app's icon that
            // stays until dismissed is the visible alternative.
            MeetingWatcher.showIconDialog(title: title, body: body)
            return
        }
        // Support diagnostic: post one alert through each channel, from a
        // LaunchServices-launched instance (`open -a HearYe --args --alert-test`).
        if CommandLine.arguments.contains("--alert-test") {
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "HearYe native test"
            content.body = "Posted through Notification Center."
            let nativeResult: String
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                nativeResult = "ok"
            } catch {
                nativeResult = error.localizedDescription
            }
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", "display notification \"Posted through osascript from a LaunchServices-launched HearYe.\" with title \"HearYe osascript test\""]
            try? osa.run()
            osa.waitUntilExit()
            let line = "\(Date()): alert-test native=\(nativeResult) osascript-exit=\(osa.terminationStatus)\n"
            let logURL = MeetingWatcher.stateDirectory.appendingPathComponent("notifications.log")
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
            return
        }
        // Support diagnostic: what macOS thinks of this app's notifications.
        if CommandLine.arguments.contains("--notification-status") {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            print("authorization:", settings.authorizationStatus.rawValue, "(0 undetermined, 1 denied, 2 authorized)")
            print("alertStyle:", settings.alertStyle.rawValue, "(0 none, 1 banner, 2 alert)")
            do {
                print("request granted:", try await center.requestAuthorization(options: [.alert, .sound]))
            } catch {
                print("request error:", error.localizedDescription)
            }
            return
        }
        HearYeApp.main()
    }
}

private struct HearYeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single window: with WindowGroup, Cmd-N opened rival windows that raced for
        // the same output filename.
        Window("HearYe", id: "main") {
            ContentView()
        }
        // Resizable down to the content's minimum, so it fits above the Dock
        // on a smaller display and scrolls; 2.0 locked the size to the content.
        .windowResizability(.contentMinSize)
    }
}
