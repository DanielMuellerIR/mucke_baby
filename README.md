# Mucke, Baby!

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

![Mucke, Baby!](icons/social-s123.png)

Mucke, Baby! is a native internet-radio player for macOS and Linux with seven visual themes, audio-reactive visualizers, listening history and optional stream recording with per-song export.

The interface is available in German and English. The iPhone sibling is [Baby, Mucke!](https://github.com/DanielMuellerIR/baby_mucke).

## Download

- **Linux x86-64:** build the native application from source with `./build.sh` and install it for your user account with `./install.sh`. The first Linux binary release is being prepared. See the [Linux guide](docs/linux.md) for dependencies and local archive installation.
- **macOS 14.2+, Apple Silicon:** [Download the signed and notarized DMG, v1.8.11](https://github.com/DanielMuellerIR/mucke_baby/releases/tag/v1.8.11). Open it and drag *Mucke, Baby!* into Applications. This remains the current macOS binary; the source tree includes later features described below.

## Linux

The native Qt 6 application has been tested on Linux Mint 22 and CachyOS on x86-64. It includes radio playback, ICY history, stations and groups, catalog search, bookmarks, recording, per-song M4A export, bounded MP3/AAC timeshift, seven themes, a miniplayer, equalizer, sleep timer and MPRIS desktop controls.

Qt, libVLC 3 and FFmpeg come from system packages. ShazamKit identification, Apple Shortcuts and Sparkle updates are specific to macOS. Build from source with `./build.sh` and `./install.sh`; installation, data paths, codec limits and tests are covered in the [Linux guide](docs/linux.md).

## Screenshots

The following screenshots show the macOS application. Linux uses native Qt widgets with the same seven themes.

<p align="center"><img src="assets/screenshots/acid.png" width="860" alt="Acid Rave theme — neon oscilloscope"></p>

| Standard | Retro | Fanzine |
|:--:|:--:|:--:|
| ![Standard](assets/screenshots/standard.png) | ![Retro](assets/screenshots/retro.png) | ![Fanzine](assets/screenshots/fanzine.png) |
| **GuitarAmp** | **Danish** | **Black MIDI** |
| ![GuitarAmp](assets/screenshots/guitaramp.png) | ![Danish](assets/screenshots/danish.png) | ![Black MIDI](assets/screenshots/midi.png) |

## Run it on macOS (CLI / headless‑friendly)

No Xcode project — the app is compiled with `swiftc` into a `.app` bundle. Xcode with its App Intents metadata tools is required. The whole toolchain is scriptable (handy for automation and AI agents):

```bash
./build.sh                                       # build -> "build/Mucke, Baby!.app" (downloads VLCKit once, ~84 MB)
./run.sh                                         # build + launch
open "build/Mucke, Baby!.app"                    # launch
"build/Mucke, Baby!.app/Contents/MacOS/MuckeBaby" # launch with logs (debug)
```

### Headless / automation

- **Headless regression tests:** `bash Tests/run-tests.sh` runs the existing harnesses on Apple Silicon macOS, without launching the app or downloading VLCKit. HTTP fixtures use loopback only. The macOS CI workflow runs the same command.
- **Export codec and position checks:** `python3 Tests/export-codecs.py` and `python3 Tests/export-positions.py` generate temporary audio fixtures and independently decode exports with FFmpeg. The position check compares marked cuts with and without fades and verifies that preview and saved files have identical bytes. Both commands require FFmpeg; source codec support depends on the macOS version.
- **Equalizer signal check:** `python3 Tests/audio-effects.py` measures the pinned VLCKit equalizer through its PCM file output, independently decoded with FFmpeg. It checks neutral gain, a selective band cut and headroom. The file output does not implement volume control, so it does not replace CoreAudio volume, mute or listening checks.
- **Automatic theme screenshots:** set `MUCKE_SHOTS=<dir>` — the app cycles through all themes, writes one PNG per theme and quits. `MUCKE_SHOT_W=<points>` overrides the window width; the layout baseline uses 940 and 660 macOS points.
  ```bash
  MUCKE_SHOTS=/tmp/shots "build/Mucke, Baby!.app/Contents/MacOS/MuckeBaby"
  ```
  Use a test account or save and restore app preferences first: the screenshot run changes the selected theme. `CFFIXED_USER_HOME` isolates files but does not reliably isolate the preferences daemon.
- **Install or release** — three entry points, deliberately separated:
  ```bash
  ./build.sh                        # build only, stays in build/
  ./install.sh                      # build, notarize, install into /Applications
  ./release.sh                      # build, notarize, package the DMG — never installs
  ./release.sh --no-finder-layout   # skip the Finder window layout (headless runs)
  ```
  Both `install.sh` and `release.sh` notarize the **app itself** and staple its ticket first.
  That matters twice over here: an app dragged out of a notarized disk image would otherwise
  carry no ticket, and Sparkle unpacks the new version on its own during an update.
  The notarytool profile name comes from `NOTARY_PROFILE` or
  `git config --local muckeBaby.notaryProfile <profile>` — keychain profiles are local to
  each Mac and never synchronized.

## macOS features

- **Temporary MP3/AAC-ADTS buffer** — opt in under Settings after confirming automatic cleanup. The buffer uses the existing metadata connection, retains at most five minutes and 32 MiB of compressed audio plus a bounded index, and stops below 10 GiB free. Disabling it, changing stations and quitting discard temporary audio. Permanent recordings and history are kept. Main and mini player share pause/resume, a buffer slider, title timeline and Live. Live starts with at least three seconds of reserve. Seeking follows complete audio-frame boundaries; decoder preroll is processed before output.

- **Stream format limits** — AAC-ADTS, including HE-AAC, uses the format reported by the VLC decoder. Ogg/Vorbis, Ogg/Opus and FLAC continue playing directly. HLS plays live; recording and timeshift are unavailable for HLS. See [format limits](docs/timeshift-buffer.md).

- **Identify music** — open the waveform search button in the player footer, then choose Identify. Shazam receives an audio fingerprint of up to 12 seconds from the music currently playing; the audio file is not sent. Audio capture permission and an internet connection are required. Cancel at any time. The main player and miniplayer share identification. Explicitly use a catalog suggestion for the current display or bookmark it separately; retain the original station text and Shazam source. ⌘↵ uses the suggestion for display, ⌘S bookmarks it and Escape closes the dialog. Pause/resume, seeking, Live, track/station changes and metadata reconnection clear old results and display choices. Identification follows the heard audio, including buffered playback; listening time and buffered reception time remain distinct. Catalog matches may name a different mix version. History and recordings remain unchanged. Bookmarks with recognition and listening provenance use exchange version 3, which older apps cannot yet import. Source builds require ShazamKit enabled under App Services for their signed App ID.

- Native macOS Shortcuts actions can play saved stations, stop radio, set volume, return the current title and save a bookmark. See [Shortcuts](docs/shortcuts.md) for parameters and recording behavior.

- Plays MP3, AAC, Ogg, Opus, FLAC and other codecs supported by VLCKit/libVLC.
- **Seven themes**, each with its own layout, textures and visualizer: Standard, Acid Rave, Retro, Fanzine, GuitarAmp, Danish, Black MIDI.
- **Fullscreen visualizer:** Open **View → Fullscreen visualizer** (⌘⇧V) for a larger view of the current theme. ⌃⌘F toggles fullscreen. ⌘B shows or hides the controls; Space starts or stops playback. Escape leaves fullscreen, and Escape in the window returns to the main player. The window shares the current title, playback and volume. Hidden or covered visualizers pause their animation; macOS Reduced Motion uses a still view.
- **Audio‑reactive visualizers** — analog VU needles, oscilloscope, spectrum bars and a piano‑roll — driven by a **CoreAudio process tap** on the app's own output. The tapped signal is normalized before analysis, so lowering the app volume does not shrink the visuals; the visuals follow the audio output (up to 30 frames per second).
- **Now‑playing** artist/title via a built‑in ICY metadata reader (selectable & copyable), with correct decoding of non‑UTF‑8 stations (UTF‑8 → Shift‑JIS/CP932 → Latin‑1, e.g. Japanese senders).
- **History panel** ("Verlauf") — every track with its date, start/end times and station, kept across station switches. Search titles or artists and combine station and date filters. Date ranges cover whole calendar days, including tracks still playing during them.
- **Bookmarks** — keep tracks from history or current playback with the heart action. The searchable list stores metadata independently of history and recordings, offers music links, and exports visible matches as UTF-8 text or CSV. Different mixes stay separate.
- **Separate deletion actions** — clearing history preserves all recordings. “Delete all recordings” requires confirmation and removes only completed recordings, preserving history and any recording in progress.
- **Recording library** — browse completed and active recordings independently of history, with date, duration, size, Finder access and local preview. Preview asks before stopping live radio. Removing a selected completed recording requires confirmation; history stays intact. History distinguishes fully and partially available audio from missing files.
- **Preview and trim exports** — Recorded-track exports open an editor with start/end adjustments and optional fades. Preview uses the exact prepared M4A file that will be saved. ⌘⇧P starts or stops preview; Escape closes the editor. Preview asks before stopping live radio, and radio resumes only when you start it manually. Changes affect the exported selection, leaving the original recording and history intact.
- **Export tags and multiple tracks** — M4A files retain artist, track title and mix version. The station is stored in the album field; the original ICY text and recording time are included in the comment. The export menu in history selects up to 100 tracks for a serial batch. Cancel individual or remaining exports and review each result. Existing batch files receive a numbered suffix rather than being replaced.

- **Mini player** — a compact window shares the live player, station selection, volume, bookmarks and recording controls. Keep it on top optionally and return to the main window without restarting playback.
- **Audio settings** — save a manual gain correction from −12 to +12 dB per local station. Adjusted playback volume is capped at 100%. An optional ten-band equalizer offers four presets, custom bands and headroom. Main and mini player open the same settings window; recordings and exports stay unprocessed. There is no automatic loudness matching.
- **Optional stream recording** (off by default) — records the playing stream to `~/Music/MuckeBaby/Aufnahmen/`, with per‑song extraction; auto‑stops when less than 10 GiB is free.
- **Live recording controls** — turn recording on or off while listening and see the effective status in the main window and menu bar. Recording begins only when audio data is successfully written; waiting, storage and write errors remain visible. It uses the existing metadata connection, which stays open for stations without song titles, and stops below 10 GiB of free storage. Ogg, Opus and FLAC renew that metadata connection for complete file headers while the audio player continues.
- **One‑click links** from the history to look a track up on Apple Music or Spotify.
- **Station groups and quick selection** — search your stations by name or URL and combine this with favorites or a group. Stations can belong to several named groups; deleting a group keeps all stations. ⌘K opens keyboard selection, and five configurable slots use ⌥⌘1–5. Quick slots remain local.
- **Library exchange** — export stations, favorites, catalog identity, groups and bookmarks as [versioned JSON](docs/library-exchange.md). Import a current or legacy station file through a preview with explicit conflict choices. Keep local data, use an imported record or retain both. Recordings, history and device settings stay local.
- **Metadata recovery** — reconnect the metadata stream independently with a bounded retry budget. System sleep closes received intervals; wake resumes only playback that was explicitly requested and has not been stopped.
- **macOS media controls** — station and track appear in Control Center. Media pause pauses buffered playback and stops direct live streams; previous/next uses the saved order of visible stations, independent of view filters. Stop and Quit release system controls.
- **Connection recovery** — up to three automatic retries after a stream failure, with 2, 5 and 15 seconds between attempts. Playback progress is monitored, network return resumes only a pending request, and Stop cancels every retry. The budget resets after a minute of stable playback.
- **Station URL repair** — catalog imports retain an optional Radio-Browser ID. In the station editor, check the catalog address, compare the old and proposed URLs, then explicitly save the URL. Your station identity, name, favorites, groups and quick slots are kept. Current playback continues with its original connection; the new address applies on the next manual start. Stations without saved catalog identity remain manually editable. JSON export/import retains the optional source ID.
- **Catalog filters and saved results** — combine country, language, genre, name, codec and minimum catalog bitrate. Browse 50 results per page, sort by votes or name, and reopen up to 20 locally saved pages within a 2 MiB cache. Saved results display their age and do not establish current stream availability.
- Station list with play/stop, per‑station show/hide and reordering; multiple **favorites** independent of startup playback. Settings offer no automatic playback, the last station, or a specific station. Missing or hidden startup targets leave playback off. Existing startup preferences are migrated once.
- Add / edit / delete stations; **curated genre lists** to import in one click.
- Playlist resolution for `.pls` / `.m3u` / `.asx` / `.xspf` / radiotime `Tune.ashx`.
- **Station catalog** from the open [radio‑browser.info](https://www.radio-browser.info) API — browse by genre, search by name, **preview** a station and add it to your list in one click.
- Light & dark mode; optional menu‑bar icon (off by default).
- **Self‑updates via Sparkle** — the app checks a signed appcast (GitHub Pages) and installs only after you confirm; no telemetry, no system profiling.

- **Sleep timer** — presets and a custom duration, with extension, cancellation and fade-out. The saved volume is retained for the next start.

### Audio‑reactivity permission

The visualizers read the app's own audio output through a CoreAudio process tap. On first launch macOS asks once for audio‑recording permission; granting it is required for the reactive visuals (with a Developer‑ID signature the grant is remembered permanently). The app volume is compensated before analysis; at full mute there is no signal to recover. Without permission the app still plays — the visualizers just idle.

## Data

On macOS, stations live in an editable JSON file:

```
~/Library/Application Support/MuckeBaby/stations.json
```

On first launch it is seeded from `Resources/seed-stations.json` if present, otherwise from the generic `Resources/seed-stations.example.json` (the only list that ships).

## Third‑party & licensing

See [`THIRD-PARTY.md`](THIRD-PARTY.md) for the full breakdown. In short:

- **VLCKit / libVLC** — **LGPLv2.1‑or‑later**, dynamically linked and replaceable inside the bundle. Source: <https://code.videolan.org/videolan/VLCKit>.
- **Theme textures & app icon** — generated locally with an Apache‑2.0 model.
- **Qt 6 and libpulse** — system libraries on Linux; full notices and source links are in `THIRD-PARTY.md`.
- **Fonts** — system fonts; the Linux Fanzine theme includes Zilla Slab under the SIL Open Font License 1.1. **Station URLs** are facts; the streams belong to their broadcasters.

**Project license:** [MIT](LICENSE) for this project's own source code. The bundled VLCKit/libVLC keeps its **LGPL‑2.1‑or‑later** license (dynamically linked and replaceable; obligations met by this notice + the source link above).

## Requirements

- **macOS source build:** macOS 14.2+, Apple Silicon and Xcode, including the App Intents metadata tools.
- **Linux:** x86-64, Qt 6.4 or newer, libVLC 3 and PulseAudio or PipeWire-Pulse. FFmpeg is needed for export. See [runtime and build dependencies](docs/linux.md).


Inspired by the Linux Mint Radio++ applet; no Radio++ code or assets are included.
