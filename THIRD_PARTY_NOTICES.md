# Third-party notices

HearYe 1.4 bundles standalone builds of these command-line tools so the
recipient does not need Homebrew, Python, or FFmpeg installed:

- [yt-dlp](https://github.com/yt-dlp/yt-dlp), licensed under the GNU General
  Public License, version 3 or later. The bundled license is in
  `HearYe.app/Contents/Resources/licenses/yt-dlp-LICENSE`.
- [FFmpeg](https://ffmpeg.org/), built with GPL-enabled components. The
  bundled license files are in `HearYe.app/Contents/Resources/licenses/`.
- [Deno](https://deno.com/), licensed under the MIT License, bundled as the
  JavaScript runtime `yt-dlp` uses to solve YouTube's player challenges. The
  bundled license is in `HearYe.app/Contents/Resources/licenses/deno-LICENSE.md`.

The bundler copies the license files found with the local Homebrew builds into
the app bundle. Before distributing a public release, review the applicable
GPL/LGPL obligations for the exact FFmpeg build, including whether the
corresponding source-code and offer requirements are satisfied. This notice is
not legal advice.
