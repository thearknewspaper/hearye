# HearYe 1.4 — code review

> **Status: fixed in 1.5.** Everything in Tiers 1–3 and the paste redesign shipped in
> version 1.5 (build 6). Four items were deliberately **not** done — see
> [Deliberately deferred](#deliberately-deferred) at the end. The refuted list is kept so
> the same findings are not re-raised later.

Review of `MeetingAudioDownloader.swift` (725 lines) for bugs and bulletproofing.

Six independent review passes (concurrency, subprocess lifecycle, state machine, input
validation, SwiftUI/UX, filesystem) plus a completeness pass. Every finding was then handed
to an adversarial verifier instructed to refute it: **80 raised, 18 refuted, 50 survived**.
The most consequential claims were then checked empirically rather than by argument — those
are marked **VERIFIED BY EXECUTION** below.

Severity reflects impact on a non-technical user with no crash reporting and no log file:
a silent wrong answer outranks a loud failure.

---

## Tier 1 — fix before the next release

### 1. Reading `terminationStatus` at pipe EOF can hard-crash the app
`MeetingAudioDownloader.swift:470` — **VERIFIED BY EXECUTION**

```swift
guard !data.isEmpty else { break }
}
let exitCode = task.terminationStatus     // <-- no waitUntilExit()
```

Pipe EOF and Foundation having *reaped* the child are two independent events. Reading
`terminationStatus` inside that window raises `NSInvalidArgumentException`. I ran this: it
goes `objc_exception_throw` → `abort`. The exception is **not catchable from Swift** — the
app vanishes, no dialog, no report.

The common case wins the race (my control test read the exit code correctly), which is
exactly why this ships and then bites someone on a loaded machine.

```swift
task.waitUntilExit()                 // required before touching terminationStatus
let exitCode = task.terminationStatus
```

Better: stop deriving completion from EOF at all. Use `terminationHandler`, where the status
is guaranteed valid, and guard it with a `didFinish` flag so it runs exactly once.

### 2. Inspection strands the spinner forever on ordinary pasted URLs
`MeetingAudioDownloader.swift:294-297` — **VERIFIED BY EXECUTION**

`inspect()` stores `inputURL.absoluteString` as an identity token, then compares it against
the raw text in the field. On mismatch both exit paths `return` **without clearing
`isInspecting`** — spinner forever, Inspect *and* Download both disabled, no recovery but
quitting.

The guard assumes `URL(string:)` round-trips. I tested 15 realistic inputs; **6 do not**:

| typed / pasted | `absoluteString` |
|---|---|
| `…/search?q=city council` | `…/search?q=city%20council` |
| `…/City Council 1-5-2026.mp4` | `…/City%20Council%201-5-2026.mp4` |
| `https://exämple.com/meeting` | `https://xn--exmple-cua.com/meeting` |
| `…/über/meeting.mp4` | `…/%C3%BCber/meeting.mp4` |
| `…/⟨zero-width space⟩zerowidth` | `…/%E2%80%8Bzerowidth` |

The zero-width row is the nasty one — copying a link out of a web page, a PDF agenda, or an
email body picks up invisible characters routinely, and the user cannot see why the app died.

Fix: identify the in-flight inspection with a token, and release the flag on *every* path.

```swift
private var inspectionToken = UUID()

let token = UUID()
inspectionToken = token
inspectionTask = Task { [weak self] in
    defer {
        if let self, self.inspectionToken == token {
            self.isInspecting = false
            self.inspectionTask = nil
        }
    }
    ...
    guard let self, self.inspectionToken == token else { return }
    probe = titledResult
}
```

Also strip zero-width and control characters on entry (see §7) — that removes a whole class
of these before they reach the parser.

### 3. A repeat filename silently saves nothing and reports success
`MeetingAudioDownloader.swift:424` + `:302` — **VERIFIED against the bundled yt-dlp source**

This is the worst outcome in the app: a journalist believes they preserved a meeting they
did not preserve.

Two ways to land on a filename that already exists:

- **Recurring titles.** Granicus `<title>` for the Jan 6 and Jan 20 "City Council Regular
  Meeting" is the identical string, so `applyAutomaticFilename` produces the identical base.
- **`hasManualFilename` never resets.** It latches true on the first manual edit
  (`:237`) and is cleared nowhere in the file. After one rename, *every* subsequent link
  reuses that name.

Then, in `HearYe.app/Contents/Resources/python/site-packages/yt_dlp/YoutubeDL.py:3326`:

```python
def existing_file(self, filepaths, *, default_overwrite=True):
    existing_files = list(filter(os.path.exists, orderedSet(filepaths)))
    if existing_files and not self.params.get('overwrites', default_overwrite):
        return existing_files[0]      # -> report_file_already_downloaded -> skip
```

`--no-overwrites` sets `overwrites=False`. With the default M4A format and YouTube's m4a
audio stream, the download target *is* the existing `<base>.m4a`, so the download is skipped;
`ExtractAudio` then reports "already in target format" and yt-dlp **exits 0**. `finishDownload`
treats 0 as proof of success and prints "Saved audio to ~/Downloads."

(Note: when the source container differs — webm/opus — the opposite happens and the previous
file is silently *overwritten*, because `ExtractAudio`'s skip is gated on
`--no-post-overwrites`, which HearYe never passes. Both behaviours are wrong for the user.)

Fix, in order of value:

1. Reset `hasManualFilename = false` in `invalidateInspectionForURLChange()`.
2. Make the name unique instead of relying on yt-dlp: if the target exists, append ` (2)`,
   ` (3)`, … before launching.
3. Verify the outcome instead of trusting the exit code — stat the expected output and
   compare `mtime`/size, or parse `[ExtractAudio] Destination:` out of the stream and use
   that as the real path.
4. Surface the actual filename in the success message: *"Saved City Council Jan 20.m4a"*,
   with a Reveal-in-Finder button (see §11).

### 4. The green "verified" badge is fabricated for every non-Granicus URL
`MeetingAudioDownloader.swift:92-99`

The fallthrough branch of `resolve()` builds a successful `ProbeResult` **without making a
single network request**. The UI then renders a green `checkmark.seal.fill` with the media
title and enables Download. A 404, a login wall, a paywalled stream, or a plain typo all
produce the same green confirmation.

`resolveTitleIfNeeded` does shell out to `yt-dlp --get-title`, but only for placeholder
titles, and a nil result is swallowed (`:386`) — so failure is indistinguishable from success.

Fix: treat a failed/empty `--get-title` as an inspection failure rather than a fallback, or
relabel the badge honestly ("Will attempt with yt-dlp" + a neutral icon) when nothing was
actually verified. Do not show a verification seal for an unverified URL.

---

## Tier 2 — real bugs

### 5. Cancelling reports "Download failed." with a red error
`MeetingAudioDownloader.swift:529`

Cancellation is recorded by writing the literal string `"Cancelling download…"` into the
user-visible `status`, and recovered by string-comparing it. But `consumeOutputLine`
overwrites `status` on **every** output line, and yt-dlp almost always emits at least one
more line after SIGTERM. Use a real flag:

```swift
private var wasCancelled = false
func cancelDownload() { wasCancelled = true; process?.terminate(); status = "Cancelling…" }
```

### 6. The title probe cannot be cancelled and has no timeout
`MeetingAudioDownloader.swift:360-384`

`withCheckedContinuation` is resumed only from `terminationHandler`. `inspectionTask?.cancel()`
cannot reach it, and nothing terminates the spawned yt-dlp. On a flaky network the spinner
runs forever with no Cancel control; each escape-and-retry leaks another live process.
`--socket-timeout 15` bounds one socket read, not total runtime.

Use `withTaskCancellationHandler`, terminate the process on cancel, and add a hard deadline.
Also move `Task.checkCancellation()` to *before* the spawn (`:293`), not after.

### 7. An 8 KB read that splits a UTF-8 sequence discards the whole chunk
`MeetingAudioDownloader.swift:464`

```swift
guard let text = String(data: data, encoding: .utf8) else { continue }
```

`readData(ofLength: 8192)` cuts at an arbitrary byte offset. Meeting titles are full of
em dashes, curly quotes and accented names, so a boundary landing mid-codepoint is not
exotic — and `continue` throws away all 8 KB, corrupting line assembly. Accumulate a `Data`
buffer and decode only complete sequences, or hold the undecodable tail for the next read.

### 8. A Granicus player redesign bricks every Granicus link
`MeetingAudioDownloader.swift:115-118`

`resolveGranicus` throws `noMediaFound` when its two hand-rolled regexes miss, instead of
degrading to the generic yt-dlp path that every other URL already uses. yt-dlp has a
maintained Granicus extractor; HearYe is strictly *less* capable on the one provider it
special-cases. Fall back rather than throw.

### 9. Quitting or closing the window orphans yt-dlp and ffmpeg
`MeetingAudioDownloader.swift:716-723`

No app delegate, no scene-teardown cleanup. Cmd-Q or the red X leaves both processes
reparented to launchd, still burning CPU and still writing into `~/Downloads`. Closing the
window also destroys the `@StateObject` — the only handle on the running `Process` — with no
confirmation. Add an `applicationShouldTerminate` prompt and terminate the child on teardown.

### 10. Host matching and scraped-URL handling are too loose
`MeetingAudioDownloader.swift:64`, `:116`, `:159`

- `host.contains("granicus.com")` matches `granicus.com.attacker.example` and
  `evilgranicus.com`, routing attacker HTML into the scraper. Use a proper suffix check:
  `host == "granicus.com" || host.hasSuffix(".granicus.com")`.
- The scraped media URL is **never scheme-validated** before being handed to yt-dlp.
  `normalizedURL` will happily produce `file://`, `data:`, or `http://127.0.0.1:…`.
  Allowlist http/https after scraping.
- `fetch()` discards `response.url`, so relative hrefs resolve against the **pre-redirect**
  URL. Municipal vanity URLs that 301 into `<city>.granicus.com` therefore build player URLs
  on the wrong host. Return the final URL and resolve against it.

### 11. `lastOutputURL` is dead, and "Open Downloads" doesn't reveal the file
`MeetingAudioDownloader.swift:248`, `:450`, `:489`

Declared, assigned once *before* `task.run()` (so it's wrong after any failure), never read
by any view. Meanwhile the only navigation is `selectFile(nil, …)`, which opens a folder of
hundreds of files without highlighting anything. Set it from the real post-processed path on
success and add a Reveal button. This is also the fix that makes §3 visible to the user.

---

## Tier 3 — polish

| Issue | Line | Note |
|---|---|---|
| Progress pegs at 100% during transcode | `:660` | Bar hits 100%, app looks frozen for minutes on a WAV of a 3-hour meeting; users cancel a finished download. Detect `[ExtractAudio]` and switch to indeterminate + "Converting audio…" |
| One transient `ERROR:` line paints the whole run red | `:671` | `errorMessage` latches on any retry line and is only cleared on exit 0 |
| Filename and format editable mid-download | `:637` | Argv was captured at launch; the UI describes a file that isn't being written. Add `.disabled(model.isDownloading)` |
| `progress` never reset on failure | `:449` | A dead run leaves a determinate bar at 37%, reading as resumable. It isn't |
| `DateFormatter` with no locale | `:574` | Japanese/Buddhist calendars yield `meeting-audio-0008-…`; Arabic locales yield non-ASCII digits. Set `Locale(identifier: "en_US_POSIX")` |
| `safeBaseName` clamps Characters, not bytes | `:546` | 180 non-Latin characters ≈ 400-540 UTF-8 bytes; APFS caps a component at 255. Also permits a leading `.` (invisible file) from a remote-controlled title |
| `decodeHTML` handles 4 entities | `:214` | `&#38;` is common in signed CDN URLs and passes through literally, breaking the token |
| No log anywhere | `:513` | Output is truncated to 140 chars, assigned to one `@Published` String, and discarded. A journalist chasing a failed download has nothing to send you. `os_log` the stream |
| `Cmd-N` opens rival windows | `:719` | Each gets its own model and the same default filename; they race for the same output path |
| Fresh `URLSession` per inspection, never invalidated | `:51` | Leaks a session per attempt |
| Audio settings are wrong for transcription | `:8` | Stereo 44.1k at `--audio-quality 0` is 10-20× larger than speech needs. Mono 16 kHz via `--postprocessor-args` would shrink files massively with no transcription loss — worth considering given MacWhisper is the consumer |

---

## The paste feature

Auto-inspect-on-paste already exists — and it is the buggiest path in the app.
`.onPasteCommand(of: [.url, .plainText])` (`:592`) → `handlePastedURL()` (`:320`):

```swift
func handlePastedURL() {
    guard let pastedText = NSPasteboard.general.string(forType: .string) else { return }
    ...
    urlText = pastedURL      // replaces the ENTIRE field
    inspect()
}
```

Three defects:

1. **Paste can vanish entirely.** `onPasteCommand` *replaces* the default paste. The modifier
   accepts `.url`, but the handler reads only `.string`. A pasteboard carrying a URL flavour
   without a plain-text one fires the handler, returns nil, and the user gets **nothing** —
   Cmd-V appears broken.
2. **It clobbers the field.** `urlText = pastedURL` destroys any selection/cursor semantics.
   Paste with text selected and the whole field is replaced, with no undo.
3. **It only covers paste.** Typing or dropping a URL gets no auto-inspection.

*(One reviewer claimed the handler also double-applies the paste on a focused field; the
verifier refuted that — when the field editor is first responder the modifier consumes the
event. Listed here only so it isn't re-raised.)*

**Recommended: drop paste interception, debounce off the text instead.** One path covers
paste, typing, and drop identically, and nothing fights AppKit for the event.

```swift
// 1. Remove .onPasteCommand entirely.

// 2. Sanitize on the way in — this also kills the §2 zero-width-space failure.
private func sanitize(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
       .unicodeScalars
       .filter { !$0.properties.isDefaultIgnorableCodePoint && !CharacterSet.controlCharacters.contains($0) }
       .reduce(into: "") { $0.unicodeScalars.append($1) }
}

// 3. Debounce inspection off urlText.
@Published var urlText = "" {
    didSet {
        guard urlText != oldValue else { return }
        invalidateInspectionForURLChange()
        scheduleAutoInspect()
    }
}

private var autoInspectTask: Task<Void, Never>?

private func scheduleAutoInspect() {
    autoInspectTask?.cancel()
    guard !isDownloading else { return }
    let candidate = sanitize(urlText)
    guard let url = URL(string: candidate),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host, host.contains(".") else { return }

    autoInspectTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, let self,
              sanitize(self.urlText) == candidate else { return }   // still the same text
        self.inspect()
    }
}
```

Then add drag-and-drop, which the app has no support for at all:

```swift
.dropDestination(for: URL.self) { urls, _ in
    guard let url = urls.first else { return false }
    model.urlText = url.absoluteString        // didSet schedules the inspection
    return true
}
```

Keep the "Inspect link" button — it's the manual escape hatch when the debounce is skipped
(and it should stay enabled so a user can retry a URL the heuristic rejected).

---

## Refuted — don't spend time on these

18 findings were killed by verification. The ones most likely to be re-raised:

- **`Task { @MainActor }` reordering output.** Two verifiers refuted it: every Task is created
  from the same serial reader queue, in program order, at the same inherited priority, and
  enqueued on the same actor executor. Not demonstrable.
- **Orphaned ffmpeg holds the pipe so EOF never arrives.** Three lenses asserted this; I built
  the exact shape (child terminated, grandchild alive holding inherited stdout) and **EOF
  arrived normally**. Not reproduced. Killing the process group is still worth doing (§9), but
  not for this reason.
- **Missing `--` end-of-options separator.** No reachable case: `inspect()` requires an
  http/https scheme, so the URL can never start with `-`. Harmless to add; not a bug.
- **Status text unreadable/uncopyable.** Refuted by the code — the full untruncated line goes
  to `errorMessage`, which the view renders with `.textSelection(.enabled)`. Only `status` is
  capped at 140.
- **`~/Downloads` missing/unwritable, disk-space precheck, completion notification.** Real
  gaps, but they fail loudly and safely. Feature requests, not defects.
- **Homebrew fallback paths as a security issue.** Crosses no privilege boundary — anything
  able to write `/usr/local/bin` can already do worse.

---

## What this review missed

Found by the user running 1.5, not by any of the six lenses:

**The progress bar never moved.** The reader loop used
`pipe.fileHandleForReading.readData(ofLength: 8_192)`, which does **not** return the bytes
currently available — it blocks until it has filled all 8192 bytes or the pipe reaches EOF.
yt-dlp's progress lines are a few dozen bytes each, so nothing was read until the process
exited, and the UI sat on "Starting download…" for the entire transfer before jumping to
100%. Measured on a 12.7s download: all 20 progress samples arrived at 12.65s. With
`availableData` the same download reports from 1.34s through 12.28s.

Worth noting why it slipped through: the call is unchanged from 1.4, three lenses read that
exact loop closely enough to argue about `terminationStatus` and Task ordering two lines
below it, and the whole review still treated the read itself as correct. Reviewing code by
reading it has a floor — this needed someone to watch the window.

## Deliberately deferred

Four things from this review are **not** in 1.5, on purpose:

1. **Process-group termination.** The finding that motivated it (orphaned ffmpeg holds the
   pipe, cancel hangs forever) was not reproducible, and doing it properly means launching
   yt-dlp through a `setsid` wrapper — real risk for no demonstrated benefit. Instead 1.5
   terminates the child on quit and prompts before quitting mid-download.
2. **Cookie / authenticated stream support.** A members-only or session-gated stream still
   fails at download time. This is a feature, not a defect, and it needs a design decision
   about where credentials would live.
3. **Splitting the file and adding a test seam.** Everything is still `private` in one
   725-line file with no injection points. Worth doing before the next round of feature
   work, not during a bug-fix release.
4. **Disk-space precheck and completion notifications.** Both were refuted as feature
   requests. A WAV of a long meeting is now far smaller anyway, since speech optimisation
   is on by default.

## Verified by execution, after the fix

- `URL(string:)` round-trip: the six failing inputs from §2 now survive sanitisation.
- Split-codepoint pipe reads: no bytes lost across an 8 KB boundary landing inside an em dash.
- `safeBaseName`: leading dot stripped, `%` neutralised, traversal flattened, 600-byte
  unicode title clamped to 180 bytes.
- Scraped-URL allowlist: `file://`, `data:`, `javascript:`, `127.0.0.1`, `169.254.169.254`
  and `192.168.x` all rejected; ordinary http(s) hosts allowed.
- Granicus host matching: `granicus.com.attacker.example` and `evilgranicus.com` rejected.
- End-to-end download through the bundled yt-dlp + FFmpeg produced
  `Audio: aac (LC), 16000 Hz, mono` — the speech path works.
- **The §3 bug reproduced verbatim**: re-running against an existing filename printed
  `[download] … has already been downloaded` / `Not converting audio` and **exited 0**.
  That is exactly the state 1.4 reported as "Saved audio to ~/Downloads."

## Suggested order

1. §1 `waitUntilExit()` — one line, removes a crash.
2. §2 inspection token — removes the unrecoverable stuck state.
3. §3 filename uniqueness + reset `hasManualFilename` + report the real path — removes the
   silent data loss.
4. §5 cancel flag, §7 UTF-8 buffering — both small and self-contained.
5. The paste redesign — replaces the flakiest code in the app with something simpler.
6. §4 honest badge, §8 Granicus fallback — these two decide whether users trust the app.
