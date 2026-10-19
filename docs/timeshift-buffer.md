# Temporary audio buffer

The settings switch enables temporary MP3/AAC-ADTS storage for the current app session.
It requires confirmation of automatic cleanup and is off after restarting the
app. Once decoder warmup and three seconds of reserve are available, playback switches to the continuous local
VLC reader. Main and mini player share pause/resume, a position slider, 15-second jumps, a title timeline and Live. Live selects the newest safe segment,
with at least three seconds of reserve; the displayed delay includes that reserve.

Received titles continue to describe permanent recording and history. The player,
bookmarks and system media information show the title at the listening position.
Seeking never appends a history entry or moves a recording boundary. Timeline
anchors retain the reception date for matching existing history entries.

Seeking selects a complete audio frame at or immediately before the requested
position (at most one frame; its duration depends on codec and sample rate). The reader starts earlier to feed the
decoder its preroll. `playbackStart` identifies the first output frame; VLC time is
relative to this output start. The available timeline begins at the first unique
segment frame, keeping its decoder preroll outside the selectable range. The
first received second is reserved for a cold MP3 decoder; it is never offered as
a production listening target. Initial handoff therefore also waits for this
warmup in addition to the three-second output reserve.

For the pinned VLCKit, `audio-desync` discards decoded preroll from the output.
Two extra frames compensate MP3 startup; AAC-ADTS needs no extra frame. The
first HE-AAC input frame produces no PCM in the direct reference. Its PCM sample
zero therefore corresponds to compressed frame one; this does not move the
selected compressed frame. AAC validates the actual decoded rate reported by VLC
against the ADTS core rate, which alone cannot distinguish LC from SBR/PS. Without that rate,
playback stays direct and the controls explain the wait. A new ICY session
invalidates the rate; returning to Live can briefly use the direct decoder again.
Millisecond quantization rounds down to preserve the selected frame. This behavior requires
the native seek PCM gate when changing VLCKit. `start-time` instead caused about
50 ms of decoder startup silence and must not replace it. File caching remains
1000 ms, clock jitter tolerance stays enabled and at least three seconds must
remain after the selected frame.

Pausing keeps the same VLC instance and reader. If the listening position falls
outside the retained window, playback stops visibly and requires Live to continue.
A metadata reconnect also invalidates a local listening position without silently
resuming it. A paused or expired position remains stopped after system wake,
requiring explicit Live. Sleep-timer expiration stops both output and reception
even while paused; manual volume and equalizer settings are retained. System Play resumes a valid pause; Stop still ends reception. Disabling
the buffer explicitly returns to the direct live stream.

The buffer receives the same metadata-free bytes as the permanent recorder from
the existing ICY connection. It creates no stream connection. Its private cache
is under `~/Library/Caches/MuckeBaby/Timeshift-v1/`; permanent recordings and
history are never cleanup targets.

## Limits and segments

- At most 300 seconds of unique audio, including the oldest decoder preroll.
- At most 32 MiB of compressed files, including duplicated preroll bytes.
- Segments contain complete audio frames, at most two seconds or 64 KiB of
  new audio (Layer III or AAC-LC-core ADTS). Each subsequent file includes up to one second of decoder preroll.
- At most 256 segments. Titles use bounded UTF-8 text and at most 64 anchors per
  segment. The atomic JSON index is capped at 1 MiB; its replacement may briefly
  require a second copy. The live index is in memory and is persisted at segment
  boundaries. It is never trusted for crash recovery or resumed playback.
- Below 10 GiB of free disk space, buffering stops. Unsupported MIME types,
  malformed frames, format changes and write failures also stop the buffer.

MP3 with stable sample rate and channel count is supported, including variable
bitrate. AAC-ADTS supports LC cores with one raw data block per frame and mono or
stereo channel configuration, including HE-AAC/SBR and HE-AAC v2/PS output.
Other AAC transports, profiles and channel layouts are rejected by the buffer.

Ogg/Vorbis, Ogg/Opus and FLAC continue playing directly through VLC; temporary
seeks are unavailable because their container headers need a separate retention
and decoder implementation. Recording still starts with fresh container headers.
HLS continues playing through VLC, but recording and this temporary buffer are
unavailable. An explicit path or an HLS response MIME type closes the ICY path
without retries or writing a manifest as audio. Existing recordings are retained.
A bounded initial marker check also rejects fragmented manifests with an incorrect
audio MIME type before either file sink receives bytes.

A frame keeps its original audio-reception date, including across fragmented
network chunks. This bounded in-memory map selects the correct history/recording
interval after recording is toggled within the same title. It is never persisted
in the cache index. Each segment holds at most 256 reception markers; the existing
duration, byte and segment bounds also limit their lifetime.

## Continuous reader

`makeReader(delay:decodedSampleRate:)` returns one non-seekable `InputStream`. Reading at the
growing end waits for new audio instead of returning a false EOF. On segment
changes, the reader skips the next file's duplicated preroll. An initial read
includes preroll; `start` and `decoderPreroll` expose its time relationship.

Production limits require at least three seconds of audio after the selected
segment start. Use the reader’s media options (MP3 demux mpga, ADTS demux aac, file caching 1000 ms). Do not
disable its clock jitter tolerance. A short initial reserve with
`:clock-jitter=0` produced a 48 ms silence insertion in a controlled test; the
three-second configuration produced PCM identical to direct file decoding for
48 kHz constant bitrate, 44.1 kHz variable bitrate and 24 kHz MPEG-2 mono.
All exported segments also decoded independently with FFmpeg.

The reader pins its current segment. If retaining that segment would exceed
the duration or byte limit, buffering stops with a reader-overrun state. It
does not silently skip audio or remove a file still in use. A closed buffer
keeps pinned files until the reader closes; a capture controller cannot start
another buffer while its previous reader remains open.

Before stopping or replacing a local VLC reader, cancel its buffer readers to
wake blocked reads, stop the old VLC instance, then close the stream. Stop,
station changes, metadata reconnects and quit invalidate the capture session.
Callbacks from previous ICY sessions cannot modify the new buffer.

## Crash cleanup and verification

Each session has a private directory and an exclusive kernel file lock. A
management lock serializes startup and cleanup. Incomplete initialization uses
a separate directory name and contains no audio. Startup removes only recognized
abandoned directories after acquiring their lock; active sessions, unknown
entries and symlinks are preserved. Old audio is discarded rather than resumed.

`Tests/run-tests.sh` covers the shared transport, heard titles, resource bounds, protected readers, cancellation,
low disk, crash restart, incomplete initialization and capture generations.
`Tests/timeshift-segments.py` prepares an isolated continuous VLC decoder and a
native settings probe without installation. Run native tests in an isolated macOS test account with exclusive
access to the app’s UI. The settings runner takes its existing authorized accessibility
helper from `MUCKE_AX_TOOL`. The `verify` mode independently compares PCM and
compressed bytes and decodes every segment. These checks do not replace human
listening or a real run on macOS 14.2.

`Tests/timeshift-transport.py prepare ROOT` builds an isolated test host with the
actual main and mini player views. Its `run` mode exercises controls, the full
300-second pause limit, system media information, recording/history protection
and quit cleanup. Run it only through the resource FIFO with the existing
`MUCKE_AX_TOOL` helper. `cleanup` terminates only recorded test-owned processes.

`Tests/timeshift-seek.py prepare ROOT` creates fresh MP3 CBR/VBR/MPEG-2/MPEG-2.5 and AAC-LC/HE-AAC/HE-AAC-v2 fixtures.
Run its native `run` mode through the resource FIFO. `verify` compares MP3 and AAC
frame positions against direct VLC file decoding, including every first output
sample, duration and segment preroll. This gate is required for changes to the
VLC clock correction and the pinned VLCKit. MP3 is compared within 0.000001
peak amplitude; AAC-LC permits 0.00001 peak with RMS below 0.000001. HE-AAC
restart state permits a peak below four 16-bit steps and SNR above 70 dB.
Lengths and frame positions must still match exactly. The AAC fixtures use a
time-varying chirp to distinguish adjacent frames.


`Tests/timeshift-integration.py` combines real RadioPlayer, ICY, Recorder,
system media commands, views and M4A exports in an isolated LaunchServices host.
It exercises recording changes while paused, frame-to-recording provenance,
timer expiry, wake handlers, a dropped connection, low-disk recovery, full buffer
pause, supported/direct-only formats, HLS and the actual buffered equalizer.
Its sleep callbacks are an integration check, not proof of full system sleep.
Native run belongs in the resource FIFO; no installation is performed.

## Explicit music identification

Identification captures the current output through the process audio tap, including
local VLC playback. The request freezes the heard ICY text, station, wall-clock
listening time and output identity/revision. Buffered requests also freeze media
position and the frame's reception date. Normal clock advancement keeps that request
valid. Pause/resume, seeks (even within one title), Live, title changes, expiration,
station changes and metadata reconnection permanently invalidate old results and
display choices. Returning to the same title or position cannot reactivate them.

A catalog match remains a suggestion. Display adoption and bookmarking are separate
explicit actions; neither rewrites received history or permanent recordings. New
bookmarks retain this provenance in format version 3; existing version 1/2 files
remain readable. A compatible recipient is required for exchange.

`Tests/timeshift-recognition.py prepare ROOT` builds controlled MP3, AAC-LC,
HE-AAC and direct-container fixtures with the actual player and shared views.
Run native `run` only through the resource FIFO. The test feeds the actual VLC
file output into the same recognition capture/service and uses a deterministic
local tone matcher; an independent PCM filter check verifies the heard tones.
The core and direct-container runs use separate fresh app instances; direct
recognition uses the production twelve-second collection period. It exercises
explicit native actions, stale replies, pause, seeks, Live,
expiration (a test-only 60-second retention window), reconnects and data protection.
This does not replace public catalog acceptance, the process-tap permission test,
human listening or the real macOS 14.2 and production-buffer sleep checks.

For a targeted follow-up, `run-direct ROOT` checks Vorbis/Opus/FLAC in DE/EN,
including a buffered HE-AAC transition, without repeating the core or views.
`verify-core ROOT` and `verify-direct ROOT` retain separate results; `verify ROOT`
requires both. The core check independently proves that reception already carried
880 Hz while the heard PCM, displayed text and saved provenance describe 440 Hz.
