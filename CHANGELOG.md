# Changelog

All notable changes to Quatuor are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.0] — 2026-11-22

### Added
- WAV and FLAC exports for individual stems, all stems, and custom mixes,
  alongside the existing MP3 export. Lossless exports use 16-bit PCM precision
  matching the generated stems, with Apple's audio APIs and no new dependency.
- An export-format picker that remembers the last selection between launches.
- **Export mix** saves the entire song using the current volume, mute, and solo
  settings. Mixes are attenuated only when necessary to prevent clipping,
  preserving the relative stem levels and dynamics.
- Whole-number volume percentages beside each stem's slider, also exposed to
  accessibility tools.
- Confirmation before **Export all** replaces existing files in the chosen folder.
- Regression tests for lossless encoding, mix levels and clipping protection,
  mute/solo behavior, and download progress with known or unknown content lengths.

### Changed
- All export filenames use the original filename followed by a title-cased stem
  name or **Mix**, for example `Song - Vocals.flac` and `Song - Mix.wav`.
- Individual stem export buttons are labeled **Export**; the shared format picker
  determines the output format. Individual and batch exports retain the stems'
  original levels; **Export mix** applies the mixer settings.
- Export encoding and mixing run off the main actor, streaming audio in chunks.
  Export controls and **New** are disabled while an export is in progress.
- The file picker uses the general audio category, and the drop zone no longer
  displays an incomplete list of accepted file extensions.
- GitHub Actions runs tests and creates a Developer ID-signed, notarized DMG on
  every push to `main` or manual run. The DMG is uploaded directly as an Actions
  artifact, with a date and commit hash in its filename; only the DMG is stapled.
- CI imports its signing certificate into a temporary keychain, derives the team
  ID from the certificate, and supplies signing settings to Xcode. The original
  developer's hard-coded team ID has been removed from the project.

### Fixed
- Seeking during playback could freeze the audio until pause/play was toggled.
  Seeking now keeps the audio engine running, and synchronized starts use a fresh
  host-clock deadline with the correct time-unit conversion.
- The solo button now responds across its entire visible area, including the
  transparent padding around the letter.
- Model downloads could remain at 0% because the async download API did not
  deliver progress callbacks. Downloads now use a delegate-driven task and show
  the current file, received bytes, and percentage when the total size is known,
  with an indeterminate indicator otherwise.
- Queued download progress updates could restore the download screen after the
  app had moved on to separation.
- MP3 exports now report file-creation and encoder-flush failures.
- CI distribution builds disable Xcode's injected debug entitlements so plain
  Release builds can pass notarization. Packaging checks for `get-task-allow`
  before submission and reports Apple's diagnostics if notarization is rejected.

## [1.3.0] — 2026-10-09

First release under the name Quatuor, as a signed and notarized `.dmg`. The
earlier releases were published as Stem, under another bundle identifier:
Quatuor installs beside it rather than over it, and downloads its model again.

### Added
- The app is distributed as `Quatuor-1.3.0.dmg`, signed with a Developer ID,
  notarized and stapled.
- README captures in English and French, taken by `outils/captures.sh` on a
  public-domain song; a social preview; a project site (`site/`).
- `make sign`, `make dmg`, `make shots`, `make release-check`.
- A file handed over at launch (`open -a Quatuor song.mp3`) opens in the window.
- The window opens tall enough to show the four stems without scrolling.

### Fixed
- The archive failed to link: it built an x86_64 slice, which neither MLX nor
  the arm64-only libmp3lame can provide. The app is built for Apple Silicon only.
- The loaded file's details were formatted by hand: "44.1 kHz" kept its decimal
  point and "ch" stayed untranslated in French. They now follow the language
  ("44,1 kHz · 2 canaux"), and the duration is truncated like the player's.
- The solo button's "S" and the progress percentage were missing from the
  string catalogue (the percentage was catalogued under a key the code never
  looked up).
- The download screen announced a ~336 MB model; it is ~670 MB.
- Quitting from the result screen left the four temporary WAV files behind.
- The app bundles the icon `make icon` generates. It shipped a copy placed by
  hand before the charter, while the generated `.icns` was versioned and unused.

### Changed
- The model cache and the temporary stem directories carry the app's own name;
  they were still written under the previous one.
- The project compiles in the Swift 6 language mode, which both README badges
  already claimed; it was building in Swift 5 mode.
- Stem names and error messages go through `Localizable.xcstrings` like every
  other user-visible string; they were hard-coded in French.
- The test suite covers audio decoding, MP3 encoding and temporary-file
  cleanup, in place of the Xcode template stubs.

### Removed
- The UI test target: template stubs that drove the app on screen and asserted
  nothing.
- `logo.png`, `capture.png`, `Scripts/fetch_models.sh`, the asset catalogue and
  three unreachable error paths — nothing referenced any of them.

## [1.2.0] — 2026-05-05

Releases 1.0.0, 1.1.0 and 1.2.0 were published the same day under the name
Stem, with another bundle identifier: Quatuor installs beside Stem, not over it.

### Added
- A progress bar for the custom model download (1.1.0).
- A file picker (1.2.0).

### Fixed
- A crash at the end of some MP3 files; temporary WAV files are cleaned up (1.2.0).

[Unreleased]: https://github.com/gwenn-ha-dev/Quatuor/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/gwenn-ha-dev/Quatuor/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/gwenn-ha-dev/Quatuor/releases/tag/v1.3.0
[1.2.0]: https://github.com/gwenn-ha-dev/Quatuor/tree/v1.2.0
