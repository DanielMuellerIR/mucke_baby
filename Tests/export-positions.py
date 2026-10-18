#!/usr/bin/env python3
"""Schnittpositionen mit Frequenzmarken und unabhängigem Decoder prüfen."""
import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import wave


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=90, **kwargs)


def main():
    repo = Path(__file__).resolve().parent.parent
    root = Path(tempfile.mkdtemp(prefix="MuckeBaby-positions-"))
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("Positionsgate benötigt ffmpeg; kein Test ausgeführt.")
    print(f"Positionsbelege: {root}", flush=True)
    rate = 48000
    frequencies = [440, 880, 1320, 1760, 2200, 2640]
    samples = array.array("h", (round(10000 * math.sin(2 * math.pi * frequencies[i // rate] * i / rate))
                               for i in range(6 * rate)))
    wav = root / "marked.wav"
    with wave.open(str(wav), "wb") as output:
        output.setparams((1, 2, rate, len(samples), "NONE", "not compressed"))
        output.writeframes(samples.tobytes())
    hashes = {}
    encoders = run([ffmpeg, "-hide_banner", "-encoders"], stdout=subprocess.PIPE, text=True).stdout
    for ext, encoder, extra in [("mp3", "libmp3lame", []), ("aac", "aac", ["-f", "adts"]),
                                ("ogg", "libvorbis" if "libvorbis" in encoders else "vorbis", ["-strict", "experimental"]),
                                ("opus", "libopus" if "libopus" in encoders else "opus", ["-strict", "experimental"])]:
        source = root / f"marked.{ext}"
        run([ffmpeg, "-v", "error", "-i", str(wav), "-ac", "2", "-c:a", encoder, *extra, str(source)])
        hashes[ext] = hashlib.sha256(source.read_bytes()).hexdigest()
    executable = root / "export-positions"
    run(["swiftc", "-parse-as-library", "-framework", "AVFoundation",
         str(repo / "Sources/ExportRange.swift"), str(repo / "Sources/SongExporter.swift"),
         str(repo / "Tests/ExportPositionHarness.swift"), "-o", str(executable)])
    run([str(executable), str(root)])

    def decode(path):
        output = run([ffmpeg, "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(rate),
                      "-f", "f32le", "-"], stdout=subprocess.PIPE).stdout
        values = array.array("f")
        values.frombytes(output)
        return values

    def frequency(values, start, length=0.04):
        chunk = values[round(start * rate):round((start + length) * rate)]
        crossings = sum(a <= 0 < b for a, b in zip(chunk, chunk[1:]))
        return crossings / (len(chunk) / rate)

    results = []
    for ext in hashes:
        assert hashlib.sha256((root / f"marked.{ext}").read_bytes()).hexdigest() == hashes[ext]
        for mode in ["hard", "faded"]:
            preview = root / f"preview-{ext}-{mode}.m4a"
            saved = root / f"saved-{ext}-{mode}.m4a"
            assert preview.read_bytes() == saved.read_bytes()
            audio = decode(saved)
            assert abs(len(audio) / rate - 2.7) < 0.04, (ext, mode, len(audio) / rate)
            for at, expected in [(0.1, 880), (0.7, 1320), (1.7, 1760), (2.6, 2200)]:
                actual = frequency(audio, at)
                assert abs(actual - expected) < 45, (ext, mode, at, actual, expected)
            transitions = []
            for expected_at, target in [(0.5, 1320), (1.5, 1760), (2.5, 2200)]:
                candidates = [i / 1000 for i in range(round((expected_at - 0.10) * 1000),
                                                     round((expected_at + 0.10) * 1000))]
                actual = next(at for at in candidates if abs(frequency(audio, at, 0.02) - target) < 60)
                assert abs(actual - expected_at) < 0.06, (ext, mode, actual, expected_at)
                transitions.append({"expected": expected_at, "measured": actual})
            rms = lambda start: math.sqrt(sum(v * v for v in audio[round(start * rate):round((start + 0.04) * rate)]) / (0.04 * rate))
            if mode == "faded":
                assert rms(0.02) < rms(1.1) * 0.2
                assert rms(2.62) < rms(1.1) * 0.2
            results.append({"source": ext, "mode": mode, "duration": len(audio) / rate,
                            "transitions": transitions, "savedSHA256": hashlib.sha256(saved.read_bytes()).hexdigest()})
        hard, faded = [result for result in results if result["source"] == ext]
        assert all(abs(a["measured"] - b["measured"]) < 0.01
                   for a, b in zip(hard["transitions"], faded["transitions"])), ext
    (root / "results.json").write_text(json.dumps({"sourceSHA256": hashes, "exports": results}, indent=2))
    print("Positionsgate: 8 Exporte, drei Schnittmarken je Datei innerhalb 60 ms; Vorhör-/Speicherbytes gleich.")


if __name__ == "__main__":
    main()
