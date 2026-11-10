#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo 'Aufruf: ui_song_backend_test.sh <build/linux/ui_song_backend_test>' >&2
    exit 2
fi
binary="$(realpath "$1")"
runtime="$(mktemp -d "${TMPDIR:-/tmp}/mucke-ui-audio.XXXXXX")"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
export PULSE_SERVER="unix:$runtime/native"
export QT_QPA_PLATFORM=offscreen
export MUCKE_UI_SONG_BACKEND=1
pulseaudio -n --daemonize=no --exit-idle-time=-1 --log-target="file:$runtime/pulse.log" \
    --load="module-native-protocol-unix socket=$runtime/native auth-anonymous=1" \
    --load="module-null-sink sink_name=mucke_ui_fixture rate=48000" &
pulse_pid=$!
cleanup() {
    kill "$pulse_pid" 2>/dev/null || true
    wait "$pulse_pid" 2>/dev/null || true
    rm -rf -- "$runtime"
}
trap cleanup EXIT HUP INT TERM
attempt=0
while [ ! -S "$runtime/native" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
done
[ -S "$runtime/native" ] || { echo 'Privater Pulse-Server nicht gestartet.' >&2; exit 1; }
"$binary"
