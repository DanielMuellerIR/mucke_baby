#!/usr/bin/env python3
"""Kontrollierte Codecfixtures und unabhängige Decodierung, ohne App oder Wiedergabe.

Benötigt ffmpeg/ffprobe im PATH. Artefakte bleiben im ausgegebenen eigenen
Temp-Verzeichnis; MUCKE_AUDIO_FIXTURES aktiviert die Codecstrecke im Swift-Harness.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile


def run(command, *, timeout=45, env=None, capture=False):
    process = subprocess.Popen(command, env=env, start_new_session=True,
                               stdout=subprocess.PIPE if capture else None,
                               stderr=subprocess.STDOUT if capture else None, text=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
    if process.returncode:
        raise RuntimeError(f"Exit {process.returncode}: {command[0]}\n{output or ''}")
    return output


def main():
    os.chdir(Path(__file__).resolve().parent.parent)
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SystemExit("Codecgate benötigt ffmpeg und ffprobe; kein Test ausgeführt.")
    root = Path(tempfile.mkdtemp(prefix="MuckeBaby-codecs-"))
    print(f"Codec-Belege: {root}", flush=True)
    encoders = run([ffmpeg, "-hide_banner", "-encoders"], capture=True)
    formats = [
        ("mp3", "libmp3lame", []),
        ("aac", "aac", ["-f", "adts"]),
        ("ogg", "libvorbis" if "libvorbis" in encoders else "vorbis", ["-strict", "experimental"]),
        ("opus", "libopus" if "libopus" in encoders else "opus", ["-strict", "experimental"]),
    ]
    hashes = {}
    for ext, encoder, extra in formats:
        source = root / f"tone.{ext}"
        run([ffmpeg, "-hide_banner", "-v", "error", "-f", "lavfi", "-i",
             "sine=frequency=440:duration=12:sample_rate=48000", "-ac", "2",
             "-c:a", encoder, *extra, str(source)])
        hashes[ext] = hashlib.sha256(source.read_bytes()).hexdigest()
    env = {**os.environ, "MUCKE_AUDIO_FIXTURES": str(root), "MUCKE_EXPORT_EVIDENCE": str(root)}
    run(["bash", "Tests/run-tests.sh"], timeout=180, env=env)
    results = []
    for ext, _, _ in formats:
        assert hashlib.sha256((root / f"tone.{ext}").read_bytes()).hexdigest() == hashes[ext]
        for mode in ["hard", "faded"]:
            destination = root / f"export-{ext}-{mode}.m4a"
            probe = json.loads(run([ffprobe, "-v", "error", "-show_entries",
                                   "stream=codec_name:format=duration", "-of", "json", str(destination)], capture=True))
            assert probe["streams"][0]["codec_name"] == "aac", probe
            assert abs(float(probe["format"]["duration"]) - 5) < 0.15, probe
            run([ffmpeg, "-v", "error", "-i", str(destination), "-f", "null", "-"])
            results.append({"source": ext, "mode": mode, "probe": probe})
    (root / "results.json").write_text(json.dumps({"sourceSHA256": hashes, "exports": results}, indent=2))
    print("Codecgate: 8 M4A-Dateien mit ffmpeg decodiert; 4 Quellen bytegleich.")


if __name__ == "__main__":
    main()
