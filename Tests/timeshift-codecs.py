#!/usr/bin/env python3
"""Kleine Ausschlussprüfung: Byteausschnitte gegen Header-/Framegrenzen.

Erzeugt eigene Fixtures und einen VLC-Dateidecoder. Den nativen Decoder auf dem
Testhost über die Ressourcen-FIFO starten; kein CoreAudio-/Hörbeleg.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=lambda x: Path(x).expanduser().resolve())
    args = parser.parse_args()
    root = args.root
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    encoders = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True, check=True).stdout
    results = []
    for ext, encoder, extra in [("mp3", "libmp3lame", []), ("aac", "aac", ["-f", "adts"]),
        ("ogg", "libvorbis" if "libvorbis" in encoders else "vorbis", ["-strict", "experimental"]),
        ("opus", "libopus" if "libopus" in encoders else "opus", ["-strict", "experimental"])]:
        source = root / ("tone." + ext)
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=18:sample_rate=48000",
                        "-ac", "2", "-c:a", encoder, *extra, str(source)], check=True, timeout=60)
        data = source.read_bytes()
        cut = root / ("cut-" + ext + "." + ext)
        cut.write_bytes(data[len(data)//3:len(data)*2//3])
        sources = [(ext, cut)]
        if ext == "aac":
            frames, offset = [], 0
            while offset + 7 <= len(data):
                assert data[offset] == 255 and data[offset+1] & 0xf6 == 0xf0
                size = ((data[offset+3] & 3) << 11) | (data[offset+4] << 3) | (data[offset+5] >> 5)
                assert size >= 7 and offset + size <= len(data)
                frames.append(data[offset:offset+size]); offset += size
            assert offset == len(data)
            aligned = root / "cut-aac-aligned.aac"
            aligned.write_bytes(b"".join(frames[len(frames)//3:len(frames)*2//3]))
            sources.append(("aac-aligned", aligned))
        for name, fixture in sources:
            decoded = subprocess.run(["ffmpeg", "-v", "error", "-i", str(fixture), "-f", "f32le", "-ac", "1", "-ar", "48000", "-"], capture_output=True, timeout=30)
            results.append({"format": name, "sourceBytes": len(data), "cutBytes": fixture.stat().st_size,
                            "pcmSamples": len(decoded.stdout)//4, "exit": decoded.returncode,
                            "errors": decoded.stderr.decode()[:2000]})
            if name == "aac-aligned":
                assert decoded.returncode == 0 and not decoded.stderr
    (root / "ffmpeg-results.json").write_text(json.dumps(results, indent=2))
    framework = repo / ".vendor/VLCKit.xcframework/macos-arm64_x86_64"
    subprocess.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.2", "-F", str(framework),
                    "-framework", "VLCKit", str(repo / "Tests/TimeshiftCodecHarness.swift"), "-o", str(root / "decode")], check=True, timeout=120)
    shutil.copytree(framework / "VLCKit.framework", root / "VLCKit.framework", symlinks=True)
    print("Vorbereitet:", root)
    print("Native Prüfung mit DYLD_FRAMEWORK_PATH=<Prüfroot> <Prüfroot>/decode <Prüfroot> über die Ressourcen-FIFO starten.")


if __name__ == "__main__":
    main()
