# Changelog

All notable changes to "Mucke, Baby!" are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
