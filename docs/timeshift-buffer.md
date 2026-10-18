# Temporary audio buffer

The settings switch enables temporary MP3 storage for the current app session.
It requires confirmation of automatic cleanup and is off after restarting the
app. It does not yet change live playback. Delayed playback controls and the
heard-title timeline remain separate work.

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

`Tests/run-tests.sh` covers resource bounds, protected readers, cancellation,
low disk, crash restart, incomplete initialization and capture generations.
`Tests/timeshift-segments.py` prepares an isolated continuous VLC decoder and a
native settings probe without installation. Run native tests in an isolated macOS test account with exclusive
access to the app’s UI. The settings runner takes its existing authorized accessibility
helper from `MUCKE_AX_TOOL`. The `verify` mode independently compares PCM and
compressed bytes and decodes every segment. These checks do not replace human
listening or a real run on macOS 14.2.
