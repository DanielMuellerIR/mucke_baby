# Temporary audio buffer

The settings switch enables temporary MP3 storage for the current app session.
It requires confirmation of automatic cleanup and is off after restarting the
app. Once three seconds are available, playback switches to the continuous local
VLC reader. Main and mini player share pause/resume, a position slider, 15-second jumps, a title timeline and Live. Live selects the newest safe segment,
with at least three seconds of reserve; the displayed delay includes that reserve.

Received titles continue to describe permanent recording and history. The player,
bookmarks and system media information show the title at the listening position.
Seeking never appends a history entry or moves a recording boundary. Timeline
anchors retain the reception date for matching existing history entries.

Seeking selects a complete MP3 frame at or immediately before the requested
position (at most one frame, about 24–72 ms, depending on sample rate). The reader starts earlier to feed the
decoder its preroll. `playbackStart` identifies the first output frame; VLC time is
relative to this output start. The available timeline begins at the first unique
segment frame, keeping its decoder preroll outside the selectable range. The
first received second is reserved for a cold MP3 decoder; it is never offered as
a production listening target. Initial handoff therefore also waits for this
warmup in addition to the three-second output reserve.

For the pinned VLCKit, `audio-desync` discards decoded preroll from the output.
Two extra MP3 frames compensate its measured startup clock offset; millisecond
quantization rounds down to preserve the selected frame. This behavior requires
the native seek PCM gate when changing VLCKit. `start-time` instead caused about
50 ms of decoder startup silence and must not replace it. File caching remains
1000 ms, clock jitter tolerance stays enabled and at least three seconds must
remain after the selected frame.

Pausing keeps the same VLC instance and reader. If the listening position falls
outside the retained window, playback stops visibly and requires Live to continue.
A metadata reconnect also invalidates a local listening position without silently
resuming it. System Play resumes a valid pause; Stop still ends reception. Disabling
the buffer explicitly returns to the direct live stream.

The buffer receives the same metadata-free bytes as the permanent recorder from
the existing ICY connection. It creates no stream connection. Its private cache
is under `~/Library/Caches/MuckeBaby/Timeshift-v1/`; permanent recordings and
history are never cleanup targets.

## Limits and segments

- At most 300 seconds of unique audio, including the oldest decoder preroll.
- At most 32 MiB of compressed files, including duplicated preroll bytes.
- Segments contain complete Layer III frames, at most two seconds or 64 KiB of
  new audio. Each subsequent file includes up to one second of decoder preroll.
- At most 256 segments. Titles use bounded UTF-8 text and at most 64 anchors per
  segment. The atomic JSON index is capped at 1 MiB; its replacement may briefly
  require a second copy. The live index is in memory and is persisted at segment
  boundaries. It is never trusted for crash recovery or resumed playback.
- Below 10 GiB of free disk space, buffering stops. Unsupported MIME types,
  malformed frames, format changes and write failures also stop the buffer.

MP3 with stable sample rate and channel count is supported, including variable
bitrate. AAC and Ogg/Opus remain unavailable until their frame/container and
decoder requirements have a separately verified implementation.

## Continuous reader

`makeReader(delay:)` returns one non-seekable `InputStream`. Reading at the
growing end waits for new audio instead of returning a false EOF. On segment
changes, the reader skips the next file's duplicated preroll. An initial read
includes preroll; `start` and `decoderPreroll` expose its time relationship.

Production limits require at least three seconds of audio after the selected
segment start. Configure VLC with `:demux=mpga` and `:file-caching=1000`. Do not
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

`Tests/timeshift-seek.py prepare ROOT` creates fresh CBR, VBR, MPEG-2 and MPEG-2.5 fixtures from 8 to 48 kHz.
Run its native `run` mode through the resource FIFO. `verify` compares 24
frame positions against direct VLC file decoding, including every first output
sample, duration and segment preroll. This gate is required for changes to the
VLC clock correction and the pinned VLCKit.
