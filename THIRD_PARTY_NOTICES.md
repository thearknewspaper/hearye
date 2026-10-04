# Third-party notices

HearYe bundles these programs and libraries so newsrooms don't need Homebrew,
Python or FFmpeg installed. Their license files are in
`HearYe.app/Contents/Resources/licenses/`.

## GPL and LGPL components: source code

| Component | Version in HearYe 2.2.x | License |
|---|---|---|
| [FFmpeg](https://ffmpeg.org/) (built with `--enable-gpl --enable-version3`) | 8.1.2 | GPL-3.0-or-later |
| [x264](https://www.videolan.org/developers/x264.html) | r3222 | GPL-2.0-or-later |
| [x265](https://www.x265.org/) | 4.2 | GPL-2.0-or-later |
| [LAME](https://lame.sourceforge.io/) | 4.0 | LGPL-2.0-or-later |
| [mpg123](https://www.mpg123.de/) | 1.33.7 | LGPL-2.1-only |

The complete corresponding source for these, with the exact build recipes and
FFmpeg's configure line, is attached to every HearYe release as
`HearYe-<version>-third-party-sources.tar.gz`:
https://github.com/thearknewspaper/hearye/releases

For at least three years after each release, the same source is also available
on request through https://github.com/thearknewspaper/hearye/issues.

The libraries are unmodified shared libraries loaded with `@loader_path`, and
ffmpeg runs as a separate program, so you can replace any of them with your own
build.

## Permissively licensed components

- [yt-dlp](https://github.com/yt-dlp/yt-dlp): Unlicense (public domain)
- [deno](https://deno.com/): MIT. It's the JavaScript runtime yt-dlp uses for YouTube.
- [Python](https://www.python.org/): PSF License, with the Python packages yt-dlp uses
  (including curl_cffi) under their own licenses in the bundle's `python` folder
- dav1d (BSD-2-Clause), libvpx (BSD-3-Clause), Opus (BSD-3-Clause),
  SVT-AV1 (BSD-3-Clause-Clear), libvmaf (BSD-2-Clause-Patent),
  Little CMS (MIT), OpenSSL (Apache-2.0), zstd (BSD-3-Clause), xz/liblzma
  (0BSD), SQLite (public domain), mpdecimal (BSD-2-Clause)

HearYe can also download a newer official yt-dlp release (Download Engine)
into `~/Library/Application Support/` after checking it against the release's
published SHA-256 list. It runs on the bundled Python.

HearYe's own code is released under the MIT License (see LICENSE).
