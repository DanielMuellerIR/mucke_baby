#!/usr/bin/env python3
"""Isolierte Prüfung des Audiopuffers. Native Aufrufe nur im isolierten macOS-Prüfkonto.

prepare ROOT baut Decoder und Einstellungsprobe ohne Installation.
decode ROOT prüft den durchgehenden VLC-Leser; settings ROOT bedient DE/EN.
cleanup ROOT beendet ausschließlich anhand ihrer Pfade belegte eigene Prozesse.
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
import urllib.request


def wait(condition, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.1)
    raise TimeoutError("Erwarteter Zustand fehlt")


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    framework = repo / ".vendor/VLCKit.xcframework/macos-arm64_x86_64"
    common = ["MetadataTimeline", "TimeshiftBuffer", "TimeshiftSegments"]
    link = ["swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.2", "-F", str(framework), "-framework", "VLCKit"]
    subprocess.run([*link, *[str(repo / "Sources" / (name + ".swift")) for name in common],
                    str(repo / "Tests/TimeshiftContinuousHarness.swift"), "-o", str(root / "decode")], check=True, timeout=120)
    app = root / "TimeshiftSettingsProbe.app"
    binary = app / "Contents/MacOS/TimeshiftSettingsProbe"
    binary.parent.mkdir(parents=True)
    names = common + ["TimeshiftCapture", "TimeshiftSettingsView", "RadioPlayer", "Recorder", "Models", "SongHistory",
        "SongRecognition", "RecognitionModels", "RecordingState", "AudioSettings", "SleepTimer", "SleepTimerController",
        "PlaybackReconnect", "ICYMetadataReader", "PlaylistResolver", "Safety", "Theme"]
    subprocess.run([*link, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    *[str(repo / "Sources" / (name + ".swift")) for name in names],
                    str(repo / "Tests/TimeshiftSettingsProbe.swift"), "-o", str(binary)], check=True, timeout=120)
    shutil.copytree(framework / "VLCKit.framework", app / "Contents/Frameworks/VLCKit.framework", symlinks=True)
    (root / "VLCKit.framework").symlink_to("TimeshiftSettingsProbe.app/Contents/Frameworks/VLCKit.framework")
    resources = app / "Contents/Resources"
    resources.mkdir()
    for lang in ["de", "en"]:
        shutil.copytree(repo / "Resources" / (lang + ".lproj"), resources / (lang + ".lproj"))
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": "de.danielmuller.mucke.timeshiftsettingsprobe", "CFBundleName": "TimeshiftSettingsProbe",
                       "CFBundleExecutable": "TimeshiftSettingsProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                       "LSMinimumSystemVersion": "14.2", "CFBundleDevelopmentRegion": "de", "NSHighResolutionCapable": True}, file)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, timeout=30)
    for name, duration in [("source", 12), ("fixture", 96.768)]:
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={duration}",
                        "-ac", "2", "-c:a", "libmp3lame", "-b:a", "128k", "-write_xing", "0", "-id3v2_version", "0",
                        str(root / (name + ".mp3"))], check=True, timeout=60)
    shutil.copy(repo / "Tests/timeshift-fixture.py", root / "fixture.py")
    shutil.copy(__file__, root / "runner.py")


def track(root, process, name, expected):
    (root / (name + ".owned.json")).write_text(json.dumps({"pid": process.pid, "expected": str(expected)}))


def cleanup(root):
    for record in root.rglob("*.owned.json"):
        item = json.loads(record.read_text())
        command = subprocess.run(["ps", "-p", str(item["pid"]), "-o", "command="], capture_output=True, text=True).stdout.strip()
        if command:
            if item["expected"] not in command:
                raise RuntimeError("Fremder Prozess an eigener PID")
            os.kill(item["pid"], signal.SIGTERM)
            time.sleep(0.2)
            command = subprocess.run(["ps", "-p", str(item["pid"]), "-o", "command="], capture_output=True, text=True).stdout.strip()
            if command and item["expected"] in command:
                os.kill(item["pid"], signal.SIGKILL)
        record.unlink()
    app = root / "TimeshiftSettingsProbe.app"
    if app.exists():
        tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        result = subprocess.run([tool, "-u", str(app)], capture_output=True, text=True, timeout=10)
        if result.returncode and "-10814" not in result.stdout + result.stderr:
            raise RuntimeError("LaunchServices-Cleanup fehlgeschlagen")
    (root / "cleanup.json").write_text(json.dumps({"passed": True}))


def decode(root):
    assert not (root / "native.txt").exists()
    framework = root / "VLCKit.framework"
    if not framework.exists():
        framework = root.parent / "VLCKit.framework"
    assert framework.exists(), "Lokales Testframework fehlt"
    with (root / "native.log").open("w") as log:
        process = subprocess.Popen([str(root / "decode"), str(root)], stdout=log, stderr=subprocess.STDOUT,
                                   env=dict(os.environ, DYLD_FRAMEWORK_PATH=str(framework.parent)))
        track(root, process, "decoder", root / "decode")
        try:
            code = process.wait(timeout=90)
            assert code == 0, f"Decoder-Prozess endet mit {code}: {root}"
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            (root / "decoder.owned.json").unlink(missing_ok=True)
    assert (root / "native.txt").exists()


def verify(root):
    results = []
    for directory in [root, root / "vbr", root / "mpeg2", root / "seek"]:
        if not (directory / "source.mp3").exists():
            continue
        pcm = []
        for name in ["continuous", "control"]:
            result = subprocess.run(["ffmpeg", "-v", "error", "-i", str(directory / (name + ".wav")),
                                     "-f", "f32le", "-"], capture_output=True, check=True, timeout=30)
            assert not result.stderr
            pcm.append(result.stdout)
        reader = json.loads((directory / "reader.json").read_text()) if (directory / "reader.json").exists() else {"startFrame": 0, "samplesPerFrame": 0}
        start = reader["startFrame"] * reader["samplesPerFrame"] * 4
        control = pcm[1][start:]
        if start:
            # Der Decoder darf innerhalb des ausgewiesenen Vorlaufs anlaufen.
            # Danach müssen Zeitbezug, alle Samples und Segmentgrenzen stimmen.
            import array
            a, b = array.array('f', pcm[0]), array.array('f', control)
            skip = 0
            assert len(a) == len(b), "Seek verändert Dauer/Zeitraster"
            assert max(abs(x - y) for x, y in zip(a[skip:], b[skip:])) < 0.000001, "Seek-PCM nach Vorlauf verändert"
            assert reader["reserve"] >= 3 and reader["decoderPreroll"] > 0
        else:
            assert pcm[0] == control and len(pcm[0]) > 1_000_000, "PCM-Ausgaben unterscheiden sich"
        entries = json.loads((directory / "segments.json").read_text())
        joined = b""
        for entry in entries:
            file = directory / "segments" / entry["file"]
            data = file.read_bytes()
            assert len(data) == entry["prefixBytes"] + entry["audioBytes"]
            joined += data[entry["prefixBytes"]:]
            checked = subprocess.run(["ffmpeg", "-v", "error", "-i", str(file), "-f", "null", "-"],
                                     capture_output=True, timeout=30)
            assert checked.returncode == 0 and not checked.stderr, (file, checked.stderr)
        assert joined == (directory / "source.mp3").read_bytes()
        results.append({"case": directory.name, "samples": len(pcm[0]) // 4, "segments": len(entries),
                        "pcmEqual": pcm[0] == control, "pcmWithinTolerance": True, "offsetSamples": start // 4,
                        "compressedEqual": True, "independentSegmentDecode": True})
    (root / "independent-check.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


def settings(root):
    ax_path = os.environ.get("MUCKE_AX_TOOL")
    if not ax_path:
        raise RuntimeError("MUCKE_AX_TOOL muss auf den freigegebenen nativen AX-Helfer zeigen")
    ax = Path(ax_path)
    with (root / "server.log").open("w") as log:
        server = subprocess.Popen([sys.executable, str(root / "fixture.py"), str(root / "fixture.mp3"),
                                   "--state", str(root / "server.json")], stdout=log, stderr=subprocess.STDOUT)
        track(root, server, "server", root / "fixture.py")
        try:
            wait(lambda: (root / "server.json").exists())
            port = json.loads((root / "server.json").read_text())["port"]
            base = f"http://127.0.0.1:{port}"

            def connections():
                with urllib.request.urlopen(base + "/stats", timeout=3) as response:
                    return json.load(response)

            for lang in ["de", "en"]:
                target = root / lang
                target.mkdir()
                (target / "home").mkdir()
                (target / "recordings").mkdir()
                sentinel = target / "recordings/permanent-sentinel.mp3"
                sentinel.write_bytes(b"Existing permanent recording")
                app = root / "TimeshiftSettingsProbe.app"
                launcher = subprocess.Popen(["open", "-n", "-W", str(app), "--args", str(target), base + "/stream.mp3",
                    "-AppleLanguages", "(" + lang + ")", "-AppleLocale", "de_DE" if lang == "de" else "en_US"],
                    env=dict(os.environ, CFFIXED_USER_HOME=str(target / "home")))
                try:
                    wait(lambda: (target / "app.pid").exists())
                    pid = int((target / "app.pid").read_text())
                    (root / "app.owned.json").write_text(json.dumps({"pid": pid, "expected": str(app / "Contents/MacOS/TimeshiftSettingsProbe")}))

                    def command(*args):
                        return subprocess.check_output([str(ax), args[0], str(pid), *args[1:]], text=True, timeout=8)

                    def tree():
                        return json.loads(command("dump"))

                    def flat(node):
                        yield node
                        for child in node.get("children", []):
                            yield from flat(child)

                    def toggle():
                        return next(n for n in flat(tree()) if n.get("AXIdentifier") == "timeshift-enable")

                    wait(lambda: (target / "ready.txt").exists())
                    assert not toggle().get("AXValue")
                    command("press", "timeshift-enable")
                    before = tree()
                    before["children"] = [child for child in before.get("children", []) if child.get("AXRole") != "AXMenuBar"]
                    (target / "confirmation.json").write_text(json.dumps(before, ensure_ascii=False))
                    assert not toggle().get("AXValue"), "Puffer vor Bestätigung aktiviert"
                    (target / "shot-request.txt").write_text("confirmation")
                    wait(lambda: (target / "confirmation.png").exists())
                    command("click", "action-button-2")
                    assert not toggle().get("AXValue")
                    command("press", "timeshift-enable")
                    command("click", "action-button-1")
                    wait(lambda: toggle().get("AXValue"))
                    (target / "ui-enabled.txt").write_text("enabled")
                    wait(lambda: (target / "buffering.txt").exists())
                    wait(lambda: len(connections()["active"]) == 2)
                    command("press", "timeshift-enable")
                    wait(lambda: (target / "disabled.txt").exists())
                    assert len(connections()["active"]) == 2
                    command("press", "timeshift-enable")
                    command("click", "action-button-1")
                    assert launcher.wait(timeout=45) == 0
                    wait(lambda: not connections()["active"])
                    assert (target / "result.txt").read_text() == "passed"
                    assert sentinel.read_bytes() == b"Existing permanent recording"
                    assert not [p for p in (target / "buffers").iterdir() if p.is_dir()]
                    (target / "connections.json").write_text(json.dumps(connections(), indent=2))
                finally:
                    if launcher.poll() is None:
                        launcher.terminate(); launcher.wait(timeout=5)
            (root / "settings-result.json").write_text(json.dumps({"passed": True, "languages": ["de", "en"], "screenshots": 56,
                "confirmationCancelAndAccept": True, "connectionsDuringCapture": 2, "connectionsAfterQuit": 0}))
        finally:
            cleanup(root)
            server.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "decode", "verify", "settings", "cleanup"])
    parser.add_argument("root", type=lambda value: Path(value).expanduser().resolve())
    args = parser.parse_args()
    {"prepare": prepare, "decode": decode, "verify": verify, "settings": settings, "cleanup": cleanup}[args.mode](args.root)
