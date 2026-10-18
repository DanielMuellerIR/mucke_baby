#!/usr/bin/env python3
"""Echten VLCKit-Equalizer über seinen PCM-Dateiausgang unabhängig messen.

Der Dateiausgang besitzt keinen Lautstärkeregler. Das Gate belegt Frequenzwirkung,
neutralen Pegel und Headroom, keinen CoreAudio-Ausgang oder manuellen Hörtest.
"""
import array
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import wave


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=60, **kwargs)


def main():
    repo = Path(__file__).resolve().parent.parent
    framework = repo / ".vendor/VLCKit.xcframework/macos-arm64_x86_64"
    ffmpeg = shutil.which("ffmpeg")
    if not (framework / "VLCKit.framework").is_dir() or not ffmpeg:
        raise SystemExit("Audiogate benötigt den gepinnten Vendor-Cache und FFmpeg; kein Test ausgeführt.")
    root = Path(tempfile.mkdtemp(prefix="MuckeBaby-audio-effects-"))
    print(f"Audioeffekt-Belege: {root}", flush=True)
    rate = 48000
    source = root / "three-tones.wav"
    samples = array.array("h", (round(4500 * sum(math.sin(2 * math.pi * f * i / rate)
                                               for f in [125, 1000, 8000])) for i in range(4 * rate)))
    with wave.open(str(source), "wb") as output:
        output.setparams((1, 2, rate, len(samples), "NONE", ""))
        output.writeframes(samples.tobytes())
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    executable = root / "audio-effects"
    run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.2", "-F", str(framework),
         "-framework", "VLCKit", str(repo / "Sources/AudioSettings.swift"),
         str(repo / "Tests/VLCAudioEffectsHarness.swift"), "-o", str(executable)])
    run([str(executable), str(root)], env={**os.environ, "DYLD_FRAMEWORK_PATH": str(framework)})
    results = {}
    for name in ["off", "flat", "cut", "headroom"]:
        data = run([ffmpeg, "-v", "error", "-i", str(root / (name + ".wav")),
                    "-f", "f32le", "-ac", "1", "-ar", str(rate), "-"], stdout=subprocess.PIPE).stdout
        values = array.array("f"); values.frombytes(data)
        assert len(values) >= 3 * rate
        segment = values[rate:2 * rate]
        def magnitude(frequency):
            return 2 * abs(sum(float(v) * complex(math.cos(-2 * math.pi * frequency * i / rate),
                                                  math.sin(-2 * math.pi * frequency * i / rate))
                               for i, v in enumerate(segment))) / len(segment)
        results[name] = {"rms": math.sqrt(sum(v * v for v in segment) / len(segment)),
                         "peak": max(map(abs, segment)),
                         "magnitudes": {str(f): magnitude(f) for f in [125, 1000, 8000]}}
    base = results["off"]["magnitudes"]
    for frequency in base:
        assert abs(results["flat"]["magnitudes"][frequency] / base[frequency] - 1) < 0.01
    assert 0.20 < results["cut"]["magnitudes"]["1000"] / base["1000"] < 0.30
    assert 0.95 < results["cut"]["magnitudes"]["125"] / base["125"] < 1.05
    assert 0.95 < results["cut"]["magnitudes"]["8000"] / base["8000"] < 1.05
    assert 0.95 < results["headroom"]["magnitudes"]["1000"] / base["1000"] < 1.05
    assert 0.45 < results["headroom"]["magnitudes"]["125"] / base["125"] < 0.55
    assert results["headroom"]["peak"] <= results["off"]["peak"] * 1.05
    assert hashlib.sha256(source.read_bytes()).hexdigest() == original
    (root / "results.json").write_text(json.dumps({"sourceSHA256": original, "cases": results,
                                                  "volumeAndCoreAudioVerified": False}, indent=2))
    print("Audioeffekte: echter PCM-Ausgang, neutraler EQ-Pegel, selektive 12-dB-Absenkung und Headroom OK; Quelle unverändert.")


if __name__ == "__main__":
    main()
