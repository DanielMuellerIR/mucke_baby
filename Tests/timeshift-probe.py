#!/usr/bin/env python3
"""Explizites, isoliertes Timeshift-Testbundle ohne Installation erstellen/starten.

prepare OUTPUT erzeugt einen neuen Prüfroot. run OUTPUT benötigt eine native
Ressourcen-FIFO-Freigabe; cleanup OUTPUT ist deren eigenständiger Cleanup.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time


def cleanup(root):
    # Nur selbst gestartete Prozesse mit passender ausführbarer Datei beenden.
    for name, expected in [("app.pid", str(root / "TimeshiftProbe.app/Contents/MacOS/TimeshiftProbe")),
                           ("server.pid", str(root / "fixture.py"))]:
        pidfile = root / name
        if not pidfile.exists():
            continue
        pid = int(pidfile.read_text())
        command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout.strip()
        if command and expected not in command:
            raise RuntimeError("Fremder Prozess an eigener PID; Cleanup abgebrochen")
        if command:
            os.kill(pid, signal.SIGTERM)
            for _ in range(50):
                command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout.strip()
                if not command or expected not in command:
                    break
                time.sleep(0.1)
            if command and expected in command:
                os.kill(pid, signal.SIGKILL)
        pidfile.unlink()
    for directory in root.glob("MuckeTimeshift-*"):
        if directory.is_symlink() or not directory.is_dir():
            raise RuntimeError("Unerwarteter Puffertyp")
        shutil.rmtree(directory)
    app = root / "TimeshiftProbe.app"
    if app.exists():
        removed = subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                  "-u", str(app)], timeout=10, capture_output=True, text=True)
        # LaunchServices meldet einen bereits abgemeldeten eigenen Pfad als
        # kLSApplicationNotFoundErr. Der zweite Cleanup bleibt damit erfolgreich.
        absent = removed.returncode == 1 and f"failed to scan {app}: -10814" in (removed.stdout + removed.stderr)
        if removed.returncode and not absent:
            raise RuntimeError("Eigene LaunchServices-Registrierung nicht entfernt: " + removed.stdout + removed.stderr)
    (root / "cleanup.json").write_text(json.dumps({"passed": True, "buffers": len(list(root.glob("MuckeTimeshift-*")))}))


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    framework = repo / ".vendor/VLCKit.xcframework/macos-arm64_x86_64"
    app = root / "TimeshiftProbe.app"
    binary = app / "Contents/MacOS/TimeshiftProbe"
    binary.parent.mkdir(parents=True)
    sources = [repo / "Sources" / (name + ".swift") for name in ["TimeshiftBuffer", "TimeshiftPlayback", "ICYMetadataReader", "Safety"]]
    sources.append(repo / "Tests/TimeshiftProbe.swift")
    subprocess.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.2", "-F", str(framework),
                    "-framework", "VLCKit", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    *map(str, sources), "-o", str(binary)], check=True, timeout=120)
    shutil.copytree(framework / "VLCKit.framework", app / "Contents/Frameworks/VLCKit.framework", symlinks=True)
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": "de.danielmuller.mucke.timeshiftprobe", "CFBundleName": "TimeshiftProbe",
                       "CFBundleExecutable": "TimeshiftProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                       "LSMinimumSystemVersion": "14.2", "NSHighResolutionCapable": True}, file)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, timeout=30)
    shutil.copy(repo / "Tests/timeshift-fixture.py", root / "fixture.py")
    shutil.copy(__file__, root / "probe.py")
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "aevalsrc='0.12*sin(2*PI*if(lt(mod(t,8.064),4.032),440,880)*t)':s=48000:d=96.768",
                    "-ac", "2", "-c:a", "libmp3lame", "-b:a", "128k", "-write_xing", "0", "-id3v2_version", "0",
                    str(root / "tone.mp3")], check=True, timeout=60)
    print(root)


def run(root):
    assert not (root / "result.json").exists(), "Frischen Prüfroot verwenden"
    with (root / "server.log").open("w") as log:
        server = subprocess.Popen([sys.executable, str(root / "fixture.py"), str(root / "tone.mp3"),
                                   "--state", str(root / "server.json")], stdout=log, stderr=subprocess.STDOUT)
        (root / "server.pid").write_text(str(server.pid))
        try:
            for _ in range(100):
                if (root / "server.json").exists():
                    break
                if server.poll() is not None:
                    raise RuntimeError("Fixture beendet")
                time.sleep(0.05)
            port = json.loads((root / "server.json").read_text())["port"]
            launcher = subprocess.Popen(["open", "-n", "-W", str(root / "TimeshiftProbe.app"), "--args",
                                         f"http://127.0.0.1:{port}/stream.mp3", str(root), "--automated"])
            rss, deadline = [], time.monotonic() + 160
            try:
                while launcher.poll() is None:
                    if time.monotonic() > deadline:
                        raise TimeoutError("Test-App läuft länger als 160 Sekunden")
                    pidfile = root / "app.pid"
                    if pidfile.exists():
                        measured = subprocess.run(["ps", "-p", pidfile.read_text().strip(), "-o", "rss="],
                                                  capture_output=True, text=True, timeout=5).stdout.strip()
                        if measured:
                            rss.append(int(measured))
                    time.sleep(0.25)
                assert launcher.returncode == 0
            finally:
                if launcher.poll() is None:
                    launcher.terminate(); launcher.wait(timeout=5)
            (root / "memory.json").write_text(json.dumps({"samples": len(rss), "peakRSSKiB": max(rss, default=0),
                                                         "firstRSSKiB": rss[0] if rss else 0}))
            import urllib.request
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/stats", timeout=5) as response:
                (root / "connections.json").write_bytes(response.read())
            result = json.loads((root / "result.json").read_text())
            assert result["passed"], result
            print(json.dumps(result, indent=2))
        finally:
            cleanup(root)
            server.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "run", "cleanup"])
    parser.add_argument("root", type=lambda x: Path(x).expanduser().resolve())
    args = parser.parse_args()
    {"prepare": prepare, "run": run, "cleanup": cleanup}[args.mode](args.root)
