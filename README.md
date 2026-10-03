# HearYe 2.2

A free Mac app that saves the audio of public meetings for transcription — one
link at a time, or by watching a newsroom's channels, Granicus archives and
recordings pages and fetching each new meeting on its own.

Built by Kevin Hessel for The Ark, the weekly newspaper serving Tiburon,
Belvedere and Strawberry since 1973 ([thearknewspaper.com](https://www.thearknewspaper.com)),
and free for any newsroom under the MIT License.

**Download:** [kevinhessel.com/hearye](https://www.kevinhessel.com/hearye) ·
[latest release](https://github.com/thearknewspaper/hearye/releases/latest).
Apple Silicon, macOS 13 or later.

## Editions

| | Free edition | The Ark edition |
|---|---|---|
| Bundle ID | `com.kevinhessel.hearye` | `com.kevin.hearye` |
| Ready-made sources | None — add your own | Tiburon, Belvedere, Reed Union, Marin BOS |
| Watch list and LaunchAgent | `~/Library/Application Support/com.kevinhessel.hearye`, `com.kevinhessel.hearye.watcher` | `~/Library/Application Support/HearYe`, `com.kevin.hearye.watcher` |
| Updates | Checks this repo's releases | In-house |

The differences live in `Editions/<Edition>/` (`Sources.json`, `Edition.plist`);
build with `EDITION=ark|public`. The two can run side by side.

## What changed in 2.2

- Choose the save folder (it was always `~/Downloads`), and optionally open
  each new file in another app. Both the window and the watcher use them.
- Watch any source a newsroom pastes: YouTube channels and playlists, Granicus
  archives (`ViewPublisher.php?view_id=N`, resolved to the body's podcast
  feed), any podcast-style RSS feed, or a page that links its recordings.
  `HearYe --resolve <link>` prints what a link resolves to.
- Download Engine: HearYe fetches the official yt-dlp release once a day when
  it's newer than the bundled one, verifies it against the release's
  SHA2-256SUMS, and keeps it in Application Support, where the launcher
  prefers it. A HearYe update that bundles something newer clears it.
- About window, offline Help guide, Report a Problem, What's New, and an
  update check against GitHub releases (shared `NewsroomKit.swift`, the same
  file Captioneer uses).

Pasting, typing, or dropping a public URL into the link field automatically
starts inspection about half a second after you stop editing; the Inspect link
button remains available for retries.

## What changed in 2.1.1

- The Reed Union School District watcher sees recordings the district hosts
  itself. RUSD now posts meetings as audio and video files on its own
  Finalsite server, whose links carry no file extension, so 2.1 skipped them
  and missed the Aug. 18 and Sept. 15, 2026, board meetings. The first check
  after upgrading fetches any such meeting it has not saved yet.
- A RUSD recording is named after its visible link label, not its hover
  title, which the district often leaves stale (the Aug. 18 link carried the
  June 8 title).
- The watcher reads only the recordings page's main content, so a video
  linked from the site menu is no longer tracked as a meeting.

## What changed in 2.1

- HearYe can watch a single YouTube playlist, for a body that shares a
  channel with many others: Marin County's Civilian Oversight Commission, for
  one, posts to the county's MarinGChannel alongside every other department.
  Paste the playlist link (`https://www.youtube.com/playlist?list=…`, or a
  video link carrying `&list=`) where a channel link goes. Each check reads
  the whole playlist, so it works whether the owner files new meetings at the
  top or the bottom. Private and deleted placeholders are ignored until the
  video is public. Old recordings added to a playlist later — anything
  published more than a week before watching began — are noted and left
  alone, not downloaded as a backlog.
- The "Optimise for transcription" option is gone, and the watcher no longer
  forces mono 16 kHz either; audio keeps its source's channels and sample
  rate, and MacWhisper does its own preparation. Files are larger: a 69-minute
  YouTube meeting that saved as 44 MB now saves as 125 MB.
- Audio is built outside `~/Downloads` and moved in only once it is finished.
  Before, the downloaded source `.webm` and the `.m4a` FFmpeg was still
  writing sat in Downloads for the whole conversion — more than a minute for
  a long meeting — where MacWhisper's watch folder could grab them. A
  cancelled or failed download now leaves nothing behind in Downloads.

## What changed in 2.0.2

- A Check now button in the watching section checks the ticked channels
  immediately, whether or not scheduled watching is switched on. The check
  runs in the background like a scheduled one, so it survives closing the
  window, and the result appears in the window when it finishes.
- While the window is open, any check — Check now or a scheduled one — shows
  which meeting it just found and a live download progress bar, then a
  converting indicator. With the app closed, a check just raises its alert.
- The scheduled watcher repairs itself. Upgrading or moving the app left the
  background job pointing at an executable that no longer existed, so every
  scheduled check silently failed while Check now still worked. Opening the
  app now rewrites the job whenever its path or schedule is out of date.

## What changed in 2.0.1

- The window can be resized again and its content scrolls, so it fits above
  the Dock on smaller displays; 2.0 sized the window rigidly to its content.
- Builds are assembled outside the Dropbox-synced source folder. A copy left
  there had its code seal broken by Dropbox sync and crashed its bundled
  Python on launch ("Python quit unexpectedly"); only the notarized zip, or
  the app installed in /Applications, should ever be run.

## What changed in 2.0

- HearYe can now watch meeting sources and fetch new recordings by itself.
  Four home-beat selectors are built in — Town of Tiburon and City of
  Belvedere (YouTube), Reed Union School District (its meeting-recordings
  page, which mixes direct audio files, Zoom cloud recordings, and Vimeo),
  and the Marin County Board of Supervisors (its Granicus podcast feed,
  which sidesteps the collapsible archive on the county site) — and any
  other YouTube channel can be added by its link (for example
  `https://www.youtube.com/@ChannelName/videos`). Each selector's name opens
  that body's own meetings page. Nothing is watched until a source is ticked
  or added and the toggle is turned on. Turning it on installs a background
  watcher (a launchd agent) that keeps checking on the chosen interval —
  every hour, 6 hours, 12 hours, or day — even after the app is quit, and
  through restarts. macOS shows a one-time "HearYe can run in the background"
  notice when watching is first enabled; that is expected, and the item can
  be managed in System Settings under Login Items & Extensions.
- The watcher polls each source lightly — the YouTube and Granicus RSS feeds,
  and the RUSD recordings page — and downloads new meetings through the same
  pipeline as a manual download: compact m4a, mono 16 kHz, saved to
  `~/Downloads`. Recordings that arrive already as AAC (Zoom, Vimeo) are now
  genuinely re-encoded to mono 16 kHz rather than stream-copied. Live and
  still-processing streams are picked up once the recording is finished.
  Videos posted before watching began are left alone.
- Vimeo postings download too, despite Vimeo walling its watch pages behind a
  login and its player behind TLS fingerprinting: HearYe reroutes a Vimeo
  link through the embed player and impersonates a real browser via the
  bundled curl_cffi library. This works for videos whose embedding is open —
  RUSD's are — while an embed-restricted video still raises the
  fetch-by-hand alert after three tries. The bundled yt-dlp is updated to
  2026.08.19.
- Every fetched meeting announces itself with a native notification carrying
  the HearYe icon, and the app's default notification style is the persistent
  kind that stays on screen until dismissed — a meeting fetched at 11 p.m. is
  still there at 8 a.m., where a normal banner would have slid away unseen.
  The first alert asks for notification permission; click Allow. On a Mac
  whose management policy refuses Notification Center registration, the alert
  arrives instead as a dialog with the HearYe icon that stays until dismissed,
  so nothing is ever lost silently. A download that fails three times gets the
  same treatment.

## What changed in 1.5.3

- The 1.5.2 YouTube fix now works on Macs without Homebrew — which is every
  reporter's Mac. Solving YouTube's player challenges requires a JavaScript
  runtime; dev machines had Homebrew's deno, so the fix tested clean, while a
  bare Mac silently fell back to formats YouTube rejects with HTTP Error 403.
  The app now bundles the deno runtime (signed with the JIT entitlements it
  needs) and tells `yt-dlp` where it is.
- After a download finishes, the prominent button is now Reveal in Finder
  instead of a re-lit "Download audio", which read as "not done yet" and
  invited an accidental second download. Downloading again is still available
  as a plain button, and Return shows the saved file instead of re-running.

## What changed in 1.5.2

- YouTube downloads no longer fail with "HTTP Error 403: Forbidden". YouTube now
  requires a proof-of-origin token for its ordinary players, and without one
  `yt-dlp` fell back to the `android_vr` player, whose media URLs YouTube
  throttles to a crawl and then refuses. HearYe now asks for the embedded
  player, which needs no token, and falls back to the usual players for videos
  that forbid embedding. Archived livestreams were hit hardest, which covers
  most meeting recordings.

## What changed in 1.5.1

- The progress bar now moves while the download runs. Previously the window sat
  on a spinner reading "Starting download…" for the whole transfer and then
  jumped straight to 100%: the reader was using `readData(ofLength:)`, which
  blocks until it has filled its entire buffer, so `yt-dlp`'s small progress
  lines went unread until the process exited.

## What changed in 1.5

- Inspection can no longer get stuck. Pasted URLs containing spaces, accented
  characters, or invisible characters picked up from a PDF or web page are
  cleaned before parsing, and the spinner is always released.
- Downloads never reuse an existing filename. A repeat meeting title now saves
  as `Title (2).m4a` rather than being silently skipped by `yt-dlp` and
  reported as a successful save.
- The completion message names the file that was actually written, and the
  button becomes Reveal in Finder.
- A new "Optimise for transcription" option (on by default) writes mono 16 kHz
  audio, which is what a transcription pass wants and a fraction of the size.
- Quitting mid-download now asks first, and stops the download rather than
  leaving `yt-dlp` running in the background.
- Cancelling reports "Download cancelled." instead of "Download failed.", and
  cleans up partial files.
- The verification badge is only green when a media source was actually
  located; links that will simply be handed to `yt-dlp` are marked as such.

## What the reporter receives

Releases are for Apple Silicon Macs only; Intel builds are no longer made. The
app bundles its own `yt-dlp`, Python runtime, deno, and FFmpeg, so the
recipient does not need Homebrew, Python, or FFmpeg installed.
HearYe saves audio to `~/Downloads` unless a different folder is chosen in the
window, and has no application-level duration limit. After inspection, the filename defaults to
the media title with macOS-unsafe characters cleaned up. A manually edited name
is kept for that link, and reset when you inspect a different one. If a file of
that name already exists, HearYe appends ` (2)`, ` (3)`, and so on rather than
overwriting or silently skipping the download.

Point MacWhisper's Watch Folder at the save folder to pick up completed audio
automatically, or use **Choose App…** to open each new file in an app.

The minimum supported system is macOS 13.0.

## Build a release

**Build Apple Silicon (`arm64`) only.** Intel builds are no longer needed. The
scripts still default to `universal`, so always pass `arm64` explicitly; an
arm64 build also needs only the Homebrew tools under `/opt/homebrew`, not a
second x86_64 Homebrew in `/usr/local`.

```sh
brew install yt-dlp ffmpeg deno
./build_release.sh arm64                  # the Ark edition
EDITION=public ./build_release.sh arm64   # the free edition
```

This creates `dist/HearYe-2.2.0-macOS-arm64.zip` (or `HearYe-Public-…`) and its SHA-256 file.

For a smooth first launch on another Mac, sign and notarize the app with an
Apple Developer ID certificate. Store the notarization profile in the
keychain, then run:

```sh
./sign_and_notarize.sh "Developer ID Application: Your Name (TEAMID)" my-notary-profile arm64
```

The signing/notarization script requires `codesign`, `xcrun notarytool`, and
`spctl`; it does not contain or request credentials itself.

## Development build

A development build can use the local Homebrew tools:

```sh
./build_app.sh arm64
open /private/tmp/hearye-build/HearYe.app
```

M4A is the default compact format; WAV is available for workflows that require
uncompressed audio.

For Granicus pages, the inspector follows the public meeting page's
`/videos/<clip>/player` iframe and extracts the public HLS `playlist.m3u8`
source before downloading it.

## GitHub distribution

Keep the source and build scripts in a GitHub repository, and attach the
notarized ZIP plus its SHA-256 file to a GitHub Release tagged `v2.1`. A GitHub
Release is the cleanest handoff for a reporter: they download one archive,
unzip it, and open HearYe.app.

After downloading, move HearYe.app to `/Applications` or `~/Applications` before
opening it. Do not run the app from Dropbox, iCloud Drive, OneDrive, or another
continuously synced folder: those services can rewrite signed nested files and
cause macOS to reject the bundled Python runtime.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) before publishing a
public release. The bundled FFmpeg build includes GPL-enabled components, so
the applicable license and source-code obligations should be reviewed before
distribution.

Use only media you are authorized to download and transcribe, and respect the source site's terms.
