#!/usr/bin/env python3
"""Isolierter nativer AP21-Prüfblock, ausschließlich über Ressourcen-FIFO starten.

prepare ROOT baut einen separaten Prüfhost ohne Installation.
run ROOT bedient die Produktansichten; cleanup ROOT räumt eigene Prozesse auf.
MUCKE_AX_TOOL benennt den vorhandenen freigegebenen AX-/HID-Helfer.
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


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    sources = root / 'sources'
    sources.mkdir()
    for file in (repo / 'Sources').glob('*.swift'):
        text = file.read_text()
        if file.name == 'MacRadioApp.swift':
            text = text.replace('@main\n', '', 1)
        (sources / file.name).write_text(text)
    shutil.copy(repo / 'Tests/TimeshiftTransportProbe.swift', root / 'Probe.swift')
    app = root / 'TimeshiftTransportProbe.app'
    binary = app / 'Contents/MacOS/TimeshiftTransportProbe'
    binary.parent.mkdir(parents=True)
    vlc = repo / '.vendor/VLCKit.xcframework/macos-arm64_x86_64'
    sparkle = repo / '.vendor/Sparkle-2.9.4'
    subprocess.run(['swiftc', '-whole-module-optimization', '-parse-as-library', '-target', 'arm64-apple-macos14.2',
        '-module-cache-path', str(repo / 'build/module-cache'), '-F', str(vlc), '-framework', 'VLCKit', '-F', str(sparkle), '-framework', 'Sparkle',
        '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', *map(str, sources.glob('*.swift')), str(root / 'Probe.swift'), '-o', str(binary)], check=True, timeout=300)
    for name, parent in [('VLCKit', vlc), ('Sparkle', sparkle)]:
        shutil.copytree(parent / (name + '.framework'), app / ('Contents/Frameworks/' + name + '.framework'), symlinks=True)
    resources = app / 'Contents/Resources'
    resources.mkdir()
    for file in (repo / 'Resources').iterdir():
        if file.name == 'seed-stations.json' or file.suffix == '.plist':
            continue
        if file.is_dir():
            shutil.copytree(file, resources / file.name)
        elif file.suffix in ['.png', '.icns', '.json']:
            shutil.copy(file, resources / file.name)
    with (app / 'Contents/Info.plist').open('wb') as file:
        plistlib.dump({'CFBundleIdentifier': 'de.danielmuller.mucke.timeshifttransportprobe', 'CFBundleName': 'TimeshiftTransportProbe',
            'CFBundleExecutable': 'TimeshiftTransportProbe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'LSMinimumSystemVersion': '14.2', 'CFBundleDevelopmentRegion': 'de', 'NSHighResolutionCapable': True}, file)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, timeout=60)
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
        r'aevalsrc=0.12*sin(2*PI*if(lt(mod(t\,8.064)\,4.032)\,440\,880)*t):s=48000:d=96.768',
        '-ac', '2', '-c:a', 'libmp3lame', '-b:a', '128k', '-write_xing', '0', '-id3v2_version', '0', str(root / 'fixture.mp3')], check=True, timeout=60)
    shutil.copy(repo / 'Tests/timeshift-fixture.py', root / 'fixture.py')
    shutil.copy(__file__, root / 'runner.py')
    subprocess.run(['swiftc', '-module-cache-path', str(repo / 'build/module-cache'), str(repo / 'Tests/MediaKeyProbe.swift'), '-o', str(root / 'media-key')], check=True, timeout=60)


def track(root, process, name, expected):
    (root / (name + '.owned.json')).write_text(json.dumps({'pid': process.pid, 'expected': str(expected)}))


def cleanup(root):
    for record in root.glob('*.owned.json'):
        item = json.loads(record.read_text())
        def command():
            return subprocess.run(['ps', '-p', str(item['pid']), '-o', 'command='], capture_output=True, text=True).stdout.strip()
        current = command()
        if current:
            if item['expected'] not in current:
                raise RuntimeError('Fremder Prozess an eigener PID')
            os.kill(item['pid'], signal.SIGTERM)
            time.sleep(0.3)
            if item['expected'] in command():
                os.kill(item['pid'], signal.SIGKILL)
        record.unlink()
    app = root / 'TimeshiftTransportProbe.app'
    if app.exists():
        tool = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
        checked = subprocess.run([tool, '-u', str(app)], capture_output=True, text=True, timeout=10)
        if checked.returncode and '-10814' not in checked.stdout + checked.stderr:
            raise RuntimeError('LaunchServices-Cleanup fehlgeschlagen')
    (root / 'cleanup.json').write_text(json.dumps({'passed': True}))


def verify(root):
    results = []
    source = (root / 'fixture.mp3').read_bytes()
    stages = {'ready', 'paused', 'sought-paused', 'resumed', 'live', 'long-pause'}
    for target in [root / 'de', root / 'en']:
        if not (target / 'passed.txt').exists():
            continue
        recordings = json.loads((target / 'recordings/recordings-index.json').read_text())
        first = min(recordings, key=lambda entry: entry['start'])
        audio = (target / 'recordings' / first['file']).read_bytes()
        # Konstante 128 kbit/s, 48 kHz, 42 Frames pro ICY-Block. Wiederholte
        # Sinusframes allein sind mehrdeutig; nur vollständige Blockanfänge zählen.
        starts = [i for i in range(0, len(source), 16128) if source[i:i + 16128] == audio[:16128]]
        assert len(starts) == 1, 'Quellbeginn der Aufnahme nicht eindeutig'
        checks = []
        for item in json.loads((target / 'observations.json').read_text()):
            if item['stage'] not in stages:
                continue
            seconds = (starts[0] / 16000 + item['position']) % 96.768
            frequency = 440 if int(seconds / 4.032) % 2 == 0 else 880
            assert str(frequency) in item['title'], 'Titel passt nicht zur markierten Audioposition'
            checks.append({'stage': item['stage'], 'position': item['position'], 'expectedHz': frequency, 'title': item['title']})
        for entry in recordings:
            checked = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(target / 'recordings' / entry['file']), '-f', 'null', '-'], capture_output=True, timeout=30)
            assert checked.returncode == 0 and not checked.stderr, 'Aufnahme nicht unabhängig decodierbar'
        assert (target / 'recordings/permanent-sentinel.mp3').read_bytes() == b'Existing recording'
        results.append({'language': target.name, 'sourceSeconds': starts[0] / 16000, 'titles': checks, 'decodedRecordings': len(recordings)})
    assert results
    (root / 'independent-check.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


def run(root):
    ax = Path(os.environ['MUCKE_AX_TOOL'])
    def wait(condition, seconds=40, target=None):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if target and (target / 'failure.txt').exists():
                raise RuntimeError((target / 'failure.txt').read_text())
            if condition():
                return
            time.sleep(0.1)
        raise TimeoutError('Erwarteter nativer Zustand fehlt')

    with (root / 'server.log').open('w') as log:
        server = subprocess.Popen([sys.executable, str(root / 'fixture.py'), str(root / 'fixture.mp3'), '--state', str(root / 'server.json')], stdout=log, stderr=subprocess.STDOUT)
        track(root, server, 'server', root / 'fixture.py')
        try:
            wait(lambda: (root / 'server.json').exists())
            port = json.loads((root / 'server.json').read_text())['port']
            base = f'http://127.0.0.1:{port}'
            def connections():
                return json.load(urllib.request.urlopen(base + '/stats', timeout=3))
            languages = os.environ.get('MUCKE_TEST_LANGUAGES', 'de,en').split(',')
            for lang in languages:
                target = root / lang
                target.mkdir()
                (target / 'home').mkdir()
                (target / 'recordings').mkdir()
                sentinel = target / 'recordings/permanent-sentinel.mp3'
                sentinel.write_bytes(b'Existing recording')
                app = root / 'TimeshiftTransportProbe.app'
                quick = os.environ.get('MUCKE_TRANSPORT_QUICK') == '1'
                launcher = subprocess.Popen(['open', '-n', '-W', str(app), '--env', 'CFFIXED_USER_HOME=' + str(target / 'home'), '--env', 'MUCKE_TRANSPORT_QUICK=' + ('1' if quick else '0'), '--args',
                    str(target), base + '/stream.mp3', '-AppleLanguages', '(' + lang + ')', '-AppleLocale', 'de_DE' if lang == 'de' else 'en_US', '-volume', '0', '-recordStreams', 'NO'], env=dict(os.environ, CFFIXED_USER_HOME=str(target / 'home')))
                wait(lambda: (target / 'app.pid').exists(), target=target)
                pid = int((target / 'app.pid').read_text())
                (root / 'app.owned.json').write_text(json.dumps({'pid': pid, 'expected': str(app / 'Contents/MacOS/TimeshiftTransportProbe')}))
                def command(action, *args):
                    return subprocess.check_output([str(ax), action, str(pid), *args], text=True, timeout=10)
                def mark(name, seconds=40):
                    wait(lambda: (target / (name + '.txt')).exists(), seconds, target)
                def press(identifier):
                    command('press', identifier)
                mark('mini-ready', 80)
                (target / 'mini-ax.json').write_text(command('dump'))
                press('timeshift-pause'); mark('paused')
                mark('seek-ready'); press('timeshift-back'); mark('sought')
                press('timeshift-pause'); mark('resumed')
                press('timeshift-live'); mark('live')
                if quick:
                    command('click', 'timeshift-position'); mark('slider-sought')
                    subprocess.run([str(root / 'media-key'), str(pid)], check=True, timeout=5)
                    mark('media-key-paused')
                    subprocess.run([str(root / 'media-key'), str(pid)], check=True, timeout=5)
                    mark('media-key-resumed')
                    (target / 'keys-done.txt').write_text('passed')
                    mark('passed')
                    assert launcher.wait(timeout=15) == 0
                    wait(lambda: not connections()['active'])
                    (root / 'app.owned.json').unlink()
                    continue
                subprocess.run([str(root / 'media-key'), str(pid)], check=True, timeout=5)
                mark('long-pause')
                mark('expired', 340)
                (target / 'expired-ax.json').write_text(command('dump'))
                assert len(connections()['active']) == 1, 'Lokale Pause hält zusätzliche VLC-Netzverbindung'
                subprocess.run([str(root / 'media-key'), str(pid)], check=True, timeout=5)
                mark('passed', 50)
                assert launcher.wait(timeout=15) == 0
                wait(lambda: not connections()['active'])
                assert sentinel.read_bytes() == b'Existing recording'
                assert not [p for p in (target / 'buffers').iterdir() if p.is_dir()]
                (target / 'connections.json').write_text(json.dumps(connections(), indent=2))
                observations = json.loads((target / 'observations.json').read_text())
                assert next(o for o in observations if o['stage'] == 'paused')['systemState'] == 2
                assert next(o for o in observations if o['stage'] == 'expired')['phase'] == 'expired'
                (root / 'app.owned.json').unlink()
            (root / 'result.json').write_text(json.dumps({'passed': True, 'languages': languages, 'productionDurationLimit': None if quick else 300, 'pauseWatchdog': not quick, 'miniplayerInput': True, 'mediaKeys': True, 'connectionsAfterQuit': 0}, indent=2))
        finally:
            cleanup(root)
            server.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'run', 'verify', 'cleanup'])
    parser.add_argument('root', type=lambda text: Path(text).expanduser().resolve())
    args = parser.parse_args()
    globals()[args.mode](args.root)
