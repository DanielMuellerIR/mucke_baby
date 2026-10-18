# Changelog

All notable changes to "Mucke, Baby!" are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## 1.9.25 — 2026-10-18

- Add a shared sleep timer in the main player and menu bar, with presets, a custom duration, extension and cancellation.
- Gently fade out and stop playback when time is up while preserving the saved volume. Cancel the timer on manual stop and prevent delayed retries after expiration.

## 1.9.24 — 2026-10-18

- Open a shared theme visualizer in a dedicated window or native fullscreen, with track information, playback, volume, hideable controls and a clear return to the main player.
- Pause visualizer animation when stopped, hidden, occluded or using reduced motion. Give the large visualizer priority over the main stage and cap animation at 30 frames per second.
- Keep the waveform flat when no audio signal is available.

## 1.9.23 — 2026-10-18

- Identify live radio from the main player and miniplayer. Use a catalog suggestion for the current display only after an explicit choice, while retaining the original station text.
- Bookmark recognized tracks with their Shazam source, recognition time, original ICY text and safe catalog link. Keep different radio mixes and existing bookmarks separate; failed writes show no success.
- Preserve recognition provenance in text, CSV and version 2 library files. Continue reading and writing version 1 when no recognition provenance is present; older applications reject version 2 instead of silently removing it.

## 1.9.22 — 2026-10-18

- Add explicit ShazamKit music identification from a bounded excerpt of the app's actual audio output, with cancellation, timeout and clear failure states.
- Discard outdated identification after playback or title changes. Keep radio metadata, bookmarks and recordings unchanged.
- Explain fingerprint transmission before identification and share the interface across all themes in German and English.

## 1.9.21 — 2026-10-18

- Add artist, track title including mix version, station and recording provenance to M4A exports. Single-file exports, preview and drag-and-drop share the same metadata.
- Export multiple history tracks through a bounded serial queue with individual and batch cancellation, retained completed files and visible results for each track.
- Preserve Unicode in export filenames and assign batch collision suffixes atomically without replacing existing files.
- Use the M4A file type for drag-and-drop so Finder keeps a single `.m4a` extension.

## 1.9.20 — 2026-10-18

- Apply station gain in decibels to the actual macOS output amplitude while preserving the existing global volume curve. Normalize visualizers against the quantized output amplitude.

## 1.9.19 — 2026-10-18

- Prevent restored main windows when a shortcut starts the app in the background; retain normal app launch behavior.
- Reject stream ports outside 1–65535 in portable library files.

## 1.9.18 — 2026-10-18

- Added native Shortcuts actions for saved stations, stop, volume, current title and bookmarks, sharing the app’s player and library.
- Added reproducible App Intents metadata extraction to the direct Swift build.

## 1.9.17 — 2026-10-18

- Exchange stations, favorites, catalog identity, groups and bookmarks through a documented versioned JSON format. Continue reading legacy station files.
- Preview new, unchanged and conflicting records before import, with explicit choices that preserve local identity and never delete existing entries.
- Commit stations and bookmarks together, reject stale previews and protect incomplete import recovery. Keep recordings, history, quick slots and device settings local.

## 1.9.16 — 2026-10-18

- Store manual gain adjustments per local station and cap the resulting playback volume at 100%. Keep recordings and exports unprocessed.
- Add shared audio settings for the main and mini player, with an optional ten-band VLCKit equalizer, four presets and custom settings. Apply headroom for boosted bands and preserve neutral volume when enabling a flat equalizer.
- Preserve the previous audio settings after a failed save and protect unknown, damaged or externally changed settings files.

## 1.9.15 — 2026-10-18

- Preview a recorded track, adjust its start and end within the available audio, and choose a hard cut or fade before saving. Preview and save use the same rendered M4A file; recordings and history remain unchanged.
- Cancel preparation or saving without replacing an existing target. Discard outdated previews after an edit, and keep one local recording preview active across windows.
- Use the same media-time cut for hard and faded exports, avoiding differing decoder lead-in and shortened Ogg/Opus output.
- Validate the complete localized time adjustment. Reject invalid decimal separators instead of silently applying an integer prefix, and keep preview/save disabled until the input is valid.

## 1.9.14 — 2026-10-18

- Add a compact player window with shared playback, station selection, volume, bookmarks and recording controls. Keep it optionally above other windows and restore its visible position.
- Keep playback running when the main window closes, prevent window reopening from repeating autoplay, and close recordings on quit even when no main window is open.

## 1.9.13 — 2026-10-18

- Browse recordings independently of history, with station, date, duration, file size, local preview and Finder actions. Confirm stopping live radio before preview; protect active recordings and confirm removal of a selected completed recording.
- Show complete, partial, missing and unreadable audio in history. Reject manipulated file paths and recover interrupted recording removals without losing an existing file's index entry.

## 1.9.12 — 2026-10-17

- Preserve the received track title when a recording longer than 24 hours starts a new container file. Close the previous history entry at the received track boundary and associate the new recording section with the correct title while playback continues.

## 1.9.11 — 2026-10-16

- Keep optional Radio-Browser station IDs when adding catalog stations and exchanging station JSON. Existing and manually added stations remain independent.
- Offer an explicit URL repair preview in the station editor. Fetch only the saved catalog identity, reject unsafe or ambiguous results, and save only the URL while retaining names, favorites, groups and quick slots.
- Keep current playback connected during repair. Manual playback controls use the saved address on the next start, and outdated health checks cannot overwrite the result for a changed URL.

## 1.9.10 — 2026-10-16

- Wrap playback and metadata recovery status in narrow windows so every theme shows the full message. Track titles remain horizontally scrollable.

## 1.9.9 — 2026-10-16

- Keep partially visible history rows at their reading position when new tracks arrive or playback closes the current entry. Restore an anchor only when it disappears from the visible results.

## 1.9.8 — 2026-10-16

- Recover the metadata connection independently with bounded retries while the audio player continues. Reject callbacks from replaced metadata sessions and retain recording safety failures across automatic retries.
- Close recording and history intervals at the last received audio boundary. Suspend an explicitly requested station for system sleep and resume it once after wake unless Stop or another selection supersedes it.

## 1.9.7 — 2026-10-16

- Publish the current station, track and live playback/loading state to macOS media controls, without a simulated duration or seek position.
- Media play/pause stops the live stream; previous/next selects visible stations in saved order. Stop, terminal failure and Quit release command handlers and metadata.
- Reject commands from superseded registrations and avoid reasserting playback state for track-only updates. Windows and the menu bar share one player and media-control lifetime.

## 1.9.6 — 2026-10-16

- Switch recording on or off during playback without replacing the audio player or opening another recording connection. The existing metadata connection stays available for audio-only streams and is renewed when container formats need fresh start headers.
- Show effective recording status after successful audio writes, with separate waiting, low-storage, connection and write/index failure states. Main window, menu bar and settings share the same persistent preference.
- Serialize capture changes and stream IDs, close each recording segment cleanly, and check free space periodically even when audio data stops arriving.

## 1.9.5 — 2026-10-16

- Combine catalog filters for name, country, language, genre, codec and minimum bitrate, with vote/name sorting and 50 results per page.
- Restore the last search and browse up to 20 locally saved pages within a 2 MiB limit. Cached results show their date and explicitly avoid claims about current stream reachability.
- Bound catalog downloads, cancel superseded searches and reject stale responses. Unknown bitrates are labeled; changing results stops the previous preview.

## 1.9.4 — 2026-10-16

- Recover from temporary stream and playlist failures with up to three cancellable retries, bounded backoff and network-return handling.
- Detect stalled startup or playback progress, reset the retry budget only after stable playback, and preserve manual Stop or station changes over late callbacks.
- Show reconnect status with a usable Stop action and clear stale track text while waiting. Each failed attempt closes metadata and recording resources before retrying.

## 1.9.3 — 2026-10-16

- Search local stations by name or URL and combine results with favorites, groups, or ungrouped stations in the main window and menu bar.
- Named groups support multiple memberships, renaming and removal without station loss; existing station arrays migrate to a versioned document on the next saved change.
- ⌘K opens a station picker with search and keyboard selection. Five configurable quick slots use ⌥⌘1–5 and disable unavailable targets.

## 1.9.2 — 2026-10-16

- Multiple station favorites persist independently of launch playback, with consistent star controls in the editor and menu bar. The menu-bar station list now receives a usable bounded height.
- Startup settings explicitly choose no playback, the last station, or a specific station. Existing preferences migrate once; unavailable targets remain stopped.
- Startup configuration uses atomic persistence, preserves newer formats, and reports recovery or storage errors without replacing the previous selection.

## [1.9.1] - 2026-10-16
### Added
- Bookmark tracks from history and current playback in a separate persistent metadata library. Search, remove and open bookmarked tracks with the existing music and lyrics actions; clearing history or recordings preserves bookmarks.
- Export visible bookmarks as UTF-8 text or CSV, preserving Unicode and quoted fields while treating formula-like cells as text. Protect the bookmark database from export replacement.
- Recover damaged bookmark files to a separate backup, preserve unknown format versions and report storage failures without showing a false saved state.

### Fixed
- Preserve the history reading position when incoming metadata updates an unfiltered list after a filter reset.

### Tests
- Bookmark identity, distinct mixes, restart persistence, independent deletion, recovery, read/write failures, protected export destinations and CSV roundtrip with an independent reader.

## [1.9.0] - 2026-10-16
### Added
- Search listening history by title, artist or original stream text, with case-, accent- and width-insensitive matching. Combine search words with station and calendar-date filters, including custom dates and tracks crossing a day boundary.
- Show each history entry's date, distinguish an empty history from an empty filter result and restore filters with one action. Preserve selection and reading position; hidden selections cannot trigger song actions.

### Changed
- New history entries follow the latest track only when already reading at the end with no active filters. A separate action returns to the latest matching entry.

### Tests
- Unicode search, combined filters, ongoing entries, inclusive calendar dates, daylight-saving transitions, retained reading anchors and a 10,000-entry history fixture.

## [1.8.11] - 2026-10-13
### Fixed
- Bind recordings and song history to their playback session, preventing later unrecorded stations from exporting earlier audio. Keep received intervals separate from media duration so bundled recordings remain fully exportable.
- Resolve ASX entries inside REPEAT elements and UTF-16 XML playlists, while retaining namespace, path and document-type checks.
- Remove the unused Danish accent-texture setting.

### Tests
- Persisted playback identities, unrecorded station switches, complete twelve-second MP3 recording/export, UTF-16 HTTP responses and rejected document-type declarations.

## [1.8.10] - 2026-10-03
### Fixed
- Completed readable recordings use their audio duration instead of callback arrival times, keeping bundled stream responses exportable.
- Recording rollover runs at the ICY parser's song boundary before subsequent audio writes. History receives the same boundary timestamp even when title delivery is delayed.
- XML playlists retain their original bytes and encoding declaration. XSPF track locations and ASX entry references are distinguished from metadata and foreign extensions.
- Removed an unused visualizer gain accessor and the unreachable fabric visualizer; the Danish theme retains its existing bars and texture.

### Tests
- Actual Latin-1 and UTF-8 XML responses, XSPF namespaces and element paths, delayed-title ICY rollover, and complete twelve-second MP3 recording/export.

## [1.8.9] - 2026-10-02
### Fixed
- Corrupt station, history and recording index files are preserved under unique backup names before replacement. Read or backup failures prevent subsequent overwrites.
- Station deletion, reordering, visibility, favorites and imports publish changes only after successful storage. Failed actions report a storage error; catalogue results remain available.
- Recording starts with the first audio bytes, excludes HTTP error responses and closes when its ICY connection ends. Failed initial index writes no longer leave unindexed recordings.
- File and drag exports share recording boundaries and stop at the available media end, including faded exports after interrupted recordings.
- ASX and XSPF playlists decode XML entities, accept UTF-8 BOMs and reject document type declarations and unrelated links.
- Audio analysis clears previous samples and levels on stop and waits for real signal after restarting.
- Initial station lists keep one favorite. English recording explanations and genre import feedback are localized. Screenshot runs restore the previous theme preference.
- App bundles include the full VLCKit and Sparkle license texts. DMG creation uses a private temporary mountpoint and cleans up its mount after failure.
- Publishing binds one GitHub destination, pushes only the requested release tag and verifies its remote object before uploading.

### Tests
- Regression coverage for persistence failures and recovery, ICY connection boundaries and error responses, export truncation, XML playlists, audio analysis reset and release mount cleanup.

## [1.8.8] - 2026-10-01
### Fixed
- Station edits report storage failures and keep the editor open. Station data and exclusive favorites are published only after successful persistence.
- Songs at a recording rollover use the new clip and a shared history/recorder timestamp.
- The ICY recorder fixture is independent of reported free disk capacity.

## [1.8.7] - 2026-09-30
### Fixed
- Playback and catalogue previews preserve the VLC state observed by each callback. A stop queued immediately after a stream error no longer hides the error message; events from an earlier station remain ignored.

### Added
- A macOS GitHub Actions workflow runs the existing headless harnesses for pushes, pull requests and manual runs, with read-only repository access and a ten-minute job limit.
- Player regression cases cover error followed by stop, stale error events after a station switch and restarting a failed preview.

## [1.8.6] - 2026-09-30
### Fixed
- Song export protects the recording even when the destination is the source itself, a symbolic link or a hard link. Failed and cancelled exports preserve an existing destination and remove their staging file.
- Cancelling an export task now cancels the media operation as well. Faded exports use the cut song's timeline, preventing loud decoder pre-roll at the beginning of the fade.
- Drag exports use separate temporary directories, sanitize long file names and remove failed exports immediately. Completed drag files remain available for transfer until the app quits, when its temporary exports are removed.
- Unreadable recordings report a codec-neutral error; format support follows the installed macOS decoders.

### Added
- Export harness for source protection, cancellation, fades, filename sanitizing and temporary file cleanup. Recorder tests cover the disk limit, rollover, collisions and crash recovery; ICY tests verify fragmented metadata and byte-exact audio forwarding.
- `Tests/export-codecs.py` generates controlled MP3, AAC, Ogg/Vorbis and Ogg/Opus fixtures, runs the production recorder/export path and independently decodes eight M4A outputs with ffmpeg.

## [1.8.5] - 2026-09-30
### Fixed
- Adding, editing and initial station seeding now enforce the central HTTP(S) URL policy before storage. The station editor keeps invalid entries open and displays a localized validation message; failed saves do not change station data or the favorite.
- Existing stations remain readable even if their URLs no longer meet the policy. Editing such a station requires correcting its URL, while imports preserve existing entries and continue to skip unsafe URLs and duplicates.
- An intentionally empty saved station list remains empty after restarting instead of being replaced with bundled defaults.

## [1.8.4] - 2026-09-08
### Fixed
- Each playback uses its own VLC player and immutable callbacks, so queued events from an earlier station cannot change the current playback or preview state.
- Stopping waits for active ICY callbacks before closing the recorder. Stop and quit cannot leave a recording open through a delayed content-type callback.

## [1.8.3] - 2026-09-07
### Fixed
- ICY titles queued before stopping or switching stations are discarded. Late responses and audio data from previous stream tasks cannot alter the current parser or recording callbacks.

## [1.8.2] - 2026-08-02
### Fixed
- Playlist detection now looks at the URL path only. A crafted playlist URL with ".m3u8" elsewhere (for example in the query) can no longer bypass the fail-closed resolver and hand the raw container to the player, and a ".pls" in the host name no longer misclassifies a direct stream as a playlist.
- When a station switch fails URL resolution, the previously playing stream now stops and the player state is cleaned up. Before, the old station kept playing audibly while the UI already showed the new station with "Invalid URL".
- Station switching and preview playback are generation-gated: media identity and request generations prevent late time and state events of a previous stream from misrepresenting playback state or aborting an in-progress station switch.
- Recording index entries are validated to plain file names on load and again before deletion, so a manipulated or restored `recordings-index.json` can no longer steer "delete all recordings" outside the recordings folder.
- Deleting recordings only removes regular files, preventing manipulated or directory index entries from deleting entire folder trees. Undeletable or non-regular files are retained in the index for diagnosis and logged. A file that is already gone still counts as deleted.
- A catalog preview stream that ends on its own can be restarted with a single click again (previously the first click was swallowed).
- A late failure of the catalog's genre-tag request no longer overwrites the results of a search that already succeeded.

### Security
- Stream URLs are redacted to scheme and host (with port if non-default) before logging, stripping path, query, fragment, and user info so tokens in paths, passwords, and query parameters no longer reach the unified log. An omitted path is indicated with `/…`.
- Release tooling is stricter: the Gatekeeper assessment of the DMG is a hard gate, `--publish` requires a clean working tree and a tag that matches the built source state, and the bundled station seed list must be byte-identical to the public example before a DMG is produced. Failed notarization runs now clean up their temporary archives.
- Published release files are treated as immutable: if a release already exists for the tag, `--publish` aborts instead of replacing its DMG. The appcast is only regenerated when a release is published, so a swapped file would no longer match the length and Ed25519 signature in the feed and Sparkle would reject the update. Raising the version is the supported path; re-running the appcast workflow manually stays available for an unchanged release.

### Added
- `Tests/fleet-rules.sh`: pins the two rules that keep an installation safe — only a bundle with a stapled notarization ticket may reach `/Applications` (ad-hoc builds stay in `build/`), and no absolute path of the build machine may end up in the shipped bundle. It reads sources only: it never builds, signs, notarizes or writes to `/Applications`, because a test that had to run the real install path to prove the guard would itself replace the installed app.
- `Tests/run-tests.sh`: a reproducible headless test entry that compiles and runs the test harness (URL policy, log redaction, playlist resolver against local HTTP fixtures, recorder deletion limits, preview coordinator) without VLCKit or network access beyond localhost.

## [1.8.1] - 2026-07-22
### Fixed
- Deleting all recordings now requires an explicit destructive confirmation and clearly states that completed files are removed permanently while history and an active recording remain.
- Rapid preview switches and overlapping catalog searches can no longer let an older asynchronous operation stop or overwrite the latest station request.
- Stream and playlist URLs now pass through one HTTP(S)-and-host policy before storage or playback; recognized playlists fail closed when they do not resolve to a safe web target.
- Station duplicate detection case-folds only URL scheme and host, preserving case-sensitive paths and queries.
- Added the missing English translations for the history and recording cleanup controls.

### Security
- The Sparkle private key is exposed only to the signing step, and every third-party GitHub Action is pinned to an immutable revision.

## [1.8.0] - 2026-07-17
### Added
- Station catalog: browse the free community database radio-browser.info (50,000+ stations) by genre, search by name, preview a station right in the dialog, and add it to your list in one click. Previews use a separate lightweight player — no history entries, no recordings. The catalog reports a "click" to the database when you preview a station, as its API guidelines request, and fails over between public API mirrors.
- Self-updates via Sparkle 2.9.4: the app checks a signed appcast on GitHub Pages ("Check for Updates …" in the app menu) and installs only after confirmation. Updates are verified twice — Apple notarization plus the project's Ed25519 signature. No automatic installs, no system profiling. Existing installations must install this version manually once; automatic updates work from the next release on.

### Changed
- The simple name-only station search has been replaced by the station catalog (same toolbar button).
- The bundle's `CFBundleVersion` now mirrors the app version on every build (Sparkle compares versions through this field).

## [1.7.42] - 2026-07-08
### Fixed
- The automatic recording stop on low disk space (< 10 GB) is now visibly reported in the footer instead of failing silently; the warning resets on the next station start.

## [1.7.41] - 2026-07-05
### Added
- The history panel's options menu now has a second set of cleanup actions that delete only the local recording files (older than a day/week/month, or all of them) while keeping the playback history intact — you can still see which songs played after the audio files are gone.

### Changed
- Visualizers now normalize the tapped app output against the app volume, so lowering listening volume no longer reduces visualizer amplitude. Fully muted output still has no recoverable signal.

### Fixed
- Recordings interrupted by a crash or quit are no longer collapsed to zero length, so every song from the recovered session stays exportable (the end time is recovered from the file rather than reset to the start).
- A stream that stops, ends, or fails on its own now releases its metadata connection, its recording file, and the audio-visualizer tap, instead of leaving them running until the next manual action. Quitting the app likewise finalizes an in-progress recording.
- Live ICY metadata parsing is now serialized on a dedicated queue, removing a data race that could corrupt state or crash when switching stations quickly.
- Two theme visualizers could loop forever (freezing the app) when laid out at zero width; both grid loops are now bounded.
- Playlist resolution caps the probe download at ~64 KB even when the server ignores the range request, preventing unbounded memory use from an endless stream.
- Recording filenames can no longer collide on a 24 h rollover (which truncated the previous file), and use a fixed Gregorian calendar so the year is correct on non-Gregorian system calendars.
- Exported song filenames built from stream titles are sanitized, so an unusual title can no longer produce a broken or hidden file.
- A station added while a reachability check is already running is now checked once the current pass finishes.
- Fixed a CoreAudio device-UID read that passed a raw pointer to an ARC-managed reference (undefined behavior plus a small per-call leak), and tightened audio-tap state access under its lock.

### Security
- The bundled VLCKit framework download is verified against a pinned SHA-256 checksum before it is extracted, linked, and code-signed (supply-chain hardening).
- Stream titles are fully percent-encoded before being placed into Apple Music / Spotify / Google search URLs, preventing query-string injection from a malicious stream. Playlist (`.pls`) parsing now accepts only the `FileN=` keys, so a crafted `Filename=` entry can no longer redirect playback.

## [1.7.37] - 2026-06-17
### Changed
- Stream recording is now **off by default**. Enabling it in Settings (or the welcome screen) persists across app restarts, as before; only a fresh install now starts with recording disabled.
- README reworded: the app is described as *inspired by* the Linux Mint "Radio++" applet rather than a reimplementation of it, reflecting features it has grown beyond the original (history, recording with per-song extraction, Apple Music / Spotify links, themes, audio-reactive visualizers).

## [1.7.36] - 2026-06-10
### Changed
- History action buttons (Apple Music, Spotify, Lyrics, Export) now show a text label beneath the icon; the Apple Music button uses the Apple logo glyph. All four labels are bottom-aligned (a fixed icon box evens out differing SF Symbol glyph heights).
- History selection highlight now uses the theme's own selection color instead of the macOS system highlight color, which could clash with a theme. The list no longer relies on the built-in (system-tinted) selection.
- Refreshed the README theme screenshots to reflect the current UI (volume control moved into the footer).

## [1.7.35] - 2026-06-10
### Changed
- Volume control moved from the header into the footer, next to the playback time (all themes). In the header it overlapped the macOS title region (`.fullSizeContentView`), where the native window-drag intercepts the mouse-down before the control receives it — so the Retro/GuitarAmp knob dragged the window instead of turning. The footer is outside that region, so a plain drag gesture works reliably.

## [1.7.34] - 2026-06-10
### Fixed
- Volume knob in the Retro and GuitarAmp themes is draggable again (superseded by 1.7.35, which moves the control into the footer — the header sits in the non-interactive window-drag region).

## [1.7.33] - 2026-06-10
### Fixed
- Retro history action icons now use dark ink on the parchment background.
- Volume knobs in the Retro and GuitarAmp themes have a larger non-draggable hit target.

### Changed
- Retro and GuitarAmp VU meters now use individual material bezels instead of a shared panel.
- GuitarAmp header plate now uses a brighter polished brass asset and stronger surface treatment.

## [1.7.32] - 2026-06-10
### Changed
- Refined bitmap material assets for the Acid Rave, Retro, Fanzine, GuitarAmp, and Danish themes.

## [1.7.31] - 2026-06-09
### Fixed
- Adaptive header bar: title no longer overlaps the traffic-light buttons at narrow window widths.
  Stop/Play label collapses to icon-only when space is tight; volume slider shrinks down to
  a minimum of 60 pt before the title yields.
- Removed `.EXE` suffix from the station-list header in the "Black MIDI" theme (`STATIONS.EXE` → `STATIONS`).

## [1.7.30] - 2026-06-09
### Added
- German/English localization (German is the development language; translatable via `.strings` files).
- One-time welcome hint displayed on first launch.
- Genre-list source and radio-browser licensing note clarified in the import dialog.

## [1.7.24] - 2026-06-07
### Added
- Audio-reactive visualizers for all seven themes (CoreAudio Process Tap → FFT via Accelerate/vDSP).
- "Black MIDI" theme: scrolling spectrogram (piano-roll top + spectrum bar bottom).
- Acid / Fanzine themes: real oscilloscope waveform from the audio tap.
- VU-meter needle ballistics for the retro theme.

### Fixed
- Spectrum-bar constant full-deflection bug (Black MIDI, Bars, EQ visualizers).
- Visible "MacRadio" identifiers renamed to "MuckeBaby" in code; data-folder migration included.
- ICY metadata: Windows-1251 (Cyrillic) and Latin-1 accent decoding added to the fallback chain.

## [1.7.18] - 2026-06-07
### Added
- Seven switchable themes: `schlicht` (native dark/light) plus `acid`, `retro`, `fanzine`,
  `stack`, `danish`, `midi` — single shared codebase, no fork.
- Three-column console layout (Stations | Stage+Visualizer | History) for design themes.
- Procedural material textures (Canvas) as theme backgrounds; bitmap textures as optional overlay.
- Audio recorder: continuous raw stream dump per session, 10 GB disk guard, 24 h rollover,
  song-boundary splitting, export via AVFoundation (mp3/aac).
- Song history panel with Apple Music / Spotify / lyrics links and drag-and-drop export.
- Genre-list import (bundled curated lists under `Resources/genre-lists/`).
- CMD +/−/0 text zoom via custom `uiZoom` / `uiFontScale` environment.

### Changed
- Audio engine replaced with VLCKit (libVLC) — adds ogg/opus/flac support.
- ICY `StreamTitle` now read via a dedicated second connection (`ICYMetadataReader`),
  because VLCKit does not expose live stream metadata.
- App icon updated to "brushed s123" (steel cone on black squircle).
- `marshall` theme renamed to `stack` to avoid trademark issues.

### Fixed
- VLC `stop()` called asynchronously to prevent stalling the next `play()`.
- Playlist containers (`.pls`/`.m3u`/`.asx`/`.xspf`/`Tune.ashx`) resolved before playback.
- History entries shorter than 5 s pruned on close; entries shorter than 20 s pruned on load.
