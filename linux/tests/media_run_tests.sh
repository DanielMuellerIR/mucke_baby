#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_root="${MUCKE_MEDIA_TEST_BUILD:-/tmp}"
mkdir -p "$build_root"
build_dir="$(mktemp -d "$build_root/mucke-media-tests.XXXXXX")"
build_dir="$(cd "$build_dir" && pwd)"
cxx="${CXX:-c++}"
test_mode="${MUCKE_MEDIA_TEST_MODE:-all}"
if [ "$test_mode" = soak-aac ]; then
export MUCKE_MEDIA_SOAK_AAC_ONLY=1
export MUCKE_MEDIA_SOAK_AAC_SECONDS="${MUCKE_MEDIA_SOAK_AAC_SECONDS:-1080}"
case "$MUCKE_MEDIA_SOAK_AAC_SECONDS" in ''|*[!0-9]*) echo 'AAC duration must be 340..1200 seconds' >&2; exit 2;; esac
if [ "$MUCKE_MEDIA_SOAK_AAC_SECONDS" -lt 340 ] || [ "$MUCKE_MEDIA_SOAK_AAC_SECONDS" -gt 1200 ]; then echo 'AAC duration must be 340..1200 seconds' >&2; exit 2; fi
fi
core_flags="$(pkg-config --cflags --libs Qt6Core)"
media_flags="$(pkg-config --cflags --libs Qt6Core Qt6Network libvlc libpulse)"
# pkg-config liefert ausschließlich Compiler-/Linker-Optionen der installierten Pakete.
if [ "$test_mode" = all ] || [ "$test_mode" = smoke ]; then
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_protocol_tests.cpp src/media/streamprotocol.cpp src/media/recorder.cpp src/types.cpp $core_flags -o "$build_dir/protocol-tests"
"$build_dir/protocol-tests"
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_disk_fixture.cpp src/media/recorder.cpp src/types.cpp -Wl,--wrap=fstatvfs $core_flags -o "$build_dir/disk-tests"
"$build_dir/disk-tests"
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_boundary_tests.cpp src/media/recorder.cpp src/types.cpp $core_flags -o "$build_dir/boundary-tests"
"$build_dir/boundary-tests"
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_health_tests.cpp $core_flags -o "$build_dir/health-tests"
"$build_dir/health-tests"
fi
if [ "${MUCKE_MEDIA_RUNTIME_TEST:-0}" != 1 ]; then exit 0; fi
moc="${MOC:-}"
if [ -z "$moc" ] && command -v qtpaths6 >/dev/null 2>&1; then
for moc_key in QT_HOST_LIBEXECS QT_INSTALL_LIBEXECS; do
moc_root="$(qtpaths6 --query "$moc_key" 2>/dev/null || true)"
if [ -n "$moc_root" ] && [ -x "$moc_root/moc" ]; then moc="$moc_root/moc"; break; fi
done
fi
if [ -z "$moc" ]; then
for moc_candidate in moc6 /usr/lib/qt6/libexec/moc /usr/lib/qt6/moc; do
if command -v "$moc_candidate" >/dev/null 2>&1; then moc="$(command -v "$moc_candidate")"; break; fi
done
fi
if [ -z "$moc" ] || ! "$moc" -v 2>&1 | grep -q 'moc 6\.'; then echo 'Qt6 moc unavailable; set MOC to its executable path' >&2; exit 2; fi
"$moc" src/media/mediaengine.h -o "$build_dir/moc_mediaengine.cpp"
"$moc" src/export/songrangeresolver.h -o "$build_dir/moc_songrangeresolver.cpp"
if [ "$test_mode" = all ] || [ "$test_mode" = smoke ]; then
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_engine_smoke.cpp src/media/mediaengine.cpp src/media/streamprotocol.cpp src/media/recorder.cpp src/media/pulsemonitor.cpp src/media/timeshift.cpp src/export/songrangeresolver.cpp src/types.cpp "$build_dir/moc_mediaengine.cpp" "$build_dir/moc_songrangeresolver.cpp" $media_flags -o "$build_dir/engine-smoke"
fi
if [ "$test_mode" != audio ] && [ "$test_mode" != soak-aac ]; then
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:a libmp3lame -b:a 128k "$build_dir/tone.mp3"
fi
pulse_dir="$build_dir/pulse"
mkdir -m 700 "$pulse_dir"
export XDG_RUNTIME_DIR="$pulse_dir"
export PULSE_SERVER="unix:$pulse_dir/native"
pulseaudio -n --daemonize=no --exit-idle-time=-1 --log-target="file:$pulse_dir/server.log" --load="module-native-protocol-unix socket=$pulse_dir/native auth-anonymous=1" --load="module-null-sink sink_name=media_fixture rate=48000" &
pulse_pid=$!
trap 'kill "$pulse_pid" 2>/dev/null || true; wait "$pulse_pid" 2>/dev/null || true' EXIT INT TERM
attempt=0
while [ ! -S "$pulse_dir/native" ] && [ "$attempt" -lt 40 ]; do sleep 0.05; attempt=$((attempt + 1)); done
if [ "$test_mode" = all ] || [ "$test_mode" = smoke ]; then
"$build_dir/engine-smoke" "$build_dir/tone.mp3"
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_pulse_tests.cpp src/media/pulsemonitor.cpp $media_flags -o "$build_dir/pulse-tests"
"$build_dir/pulse-tests"
fi
if [ "$test_mode" != audio ] && [ "$test_mode" != song ] && [ "$test_mode" != lifecycle ] && [ "$test_mode" != soak ] && [ "$test_mode" != soak-aac ]; then
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_timeshift_smoke.cpp src/media/mediaengine.cpp src/media/streamprotocol.cpp src/media/recorder.cpp src/media/pulsemonitor.cpp src/media/timeshift.cpp src/export/songrangeresolver.cpp src/types.cpp "$build_dir/moc_mediaengine.cpp" "$build_dir/moc_songrangeresolver.cpp" $media_flags -o "$build_dir/timeshift-smoke"
if [ "$test_mode" != aac ]; then
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:a libmp3lame -b:a 128k -write_xing 0 -id3v2_version 0 "$build_dir/live.mp3"
"$build_dir/timeshift-smoke" "$build_dir/live.mp3"
if [ "$test_mode" != seek ]; then
"$build_dir/timeshift-smoke" "$build_dir/live.mp3" overrun
"$build_dir/timeshift-smoke" "$build_dir/tone.mp3" fallback
fi
fi
if [ "$test_mode" = all ] || [ "$test_mode" = aac ]; then
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:a aac -b:a 128k -aac_pns 0 -f adts "$build_dir/live48.aac"
"$build_dir/timeshift-smoke" "$build_dir/live48.aac"
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=440:sample_rate=24000 -t 20 -c:a aac -b:a 128k -aac_pns 0 -f adts "$build_dir/expanded24.aac"
"$build_dir/timeshift-smoke" "$build_dir/expanded24.aac" fallback
fi
fi
if [ "$test_mode" = all ] || [ "$test_mode" = song ]; then
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_song_export_smoke.cpp src/media/mediaengine.cpp src/media/streamprotocol.cpp src/media/recorder.cpp src/media/pulsemonitor.cpp src/media/timeshift.cpp src/export/songrangeresolver.cpp src/types.cpp "$build_dir/moc_mediaengine.cpp" "$build_dir/moc_songrangeresolver.cpp" $media_flags -o "$build_dir/song-export-smoke"
"$build_dir/song-export-smoke" "$build_dir/tone.mp3"
fi
if [ "$test_mode" = all ] || [ "$test_mode" = lifecycle ]; then
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:a libmp3lame -b:a 128k -write_xing 0 -id3v2_version 0 "$build_dir/sleep.mp3"
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_sleep_smoke.cpp src/media/mediaengine.cpp src/media/streamprotocol.cpp src/media/recorder.cpp src/media/pulsemonitor.cpp src/media/timeshift.cpp src/export/songrangeresolver.cpp src/types.cpp "$build_dir/moc_mediaengine.cpp" "$build_dir/moc_songrangeresolver.cpp" $media_flags -o "$build_dir/sleep-smoke"
"$build_dir/sleep-smoke" "$build_dir/sleep.mp3"
fi
if [ "$test_mode" = soak ] || [ "$test_mode" = soak-aac ]; then
soak_mp3="-"
if [ "$test_mode" = soak ]; then
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:a libmp3lame -b:a 128k -write_xing 0 -id3v2_version 0 "$build_dir/soak.mp3"
soak_mp3="$build_dir/soak.mp3"
fi
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 -c:a aac -b:a 128k -aac_pns 0 -f adts "$build_dir/soak.aac"
$cxx -std=c++17 -fPIC -Wall -Wextra tests/media_soak_smoke.cpp src/media/mediaengine.cpp src/media/streamprotocol.cpp src/media/recorder.cpp src/media/pulsemonitor.cpp src/media/timeshift.cpp src/export/songrangeresolver.cpp src/types.cpp "$build_dir/moc_mediaengine.cpp" "$build_dir/moc_songrangeresolver.cpp" $media_flags -o "$build_dir/media-soak"
soak_output="${MUCKE_MEDIA_SOAK_OUTPUT:-$build_dir}"
mkdir -p "$soak_output"
"$build_dir/media-soak" "$soak_mp3" "$build_dir/soak.aac" "$soak_output/soak-$$"
exit 0
fi
if [ "$test_mode" = smoke ] || [ "$test_mode" = timeshift ] || [ "$test_mode" = aac ] || [ "$test_mode" = song ] || [ "$test_mode" = lifecycle ] || [ "$test_mode" = seek ]; then exit 0; fi
$cxx -std=c++17 -fPIC -Wall -Wextra -DMUCKE_MEDIA_TESTING tests/media_audio_measurement.cpp src/media/mediaengine.cpp src/media/streamprotocol.cpp src/media/recorder.cpp src/media/pulsemonitor.cpp src/media/timeshift.cpp src/export/songrangeresolver.cpp src/types.cpp "$build_dir/moc_mediaengine.cpp" "$build_dir/moc_songrangeresolver.cpp" $media_flags -o "$build_dir/audio-measurement"
ffmpeg -hide_banner -loglevel error -n -f lavfi -i sine=frequency=1000:sample_rate=48000 -t 80 -c:a pcm_s16le "$build_dir/tone.wav"
"$build_dir/audio-measurement" "$build_dir/tone.wav"
