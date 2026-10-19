#!/usr/bin/env python3
"""Musikerkennung am nativen VLC-Ausgang; run nur über Ressourcen-FIFO.

Der lokale Matcher prüft kontrollierte Töne statt des öffentlichen Katalogs.
Die Ausgangs-PCM-Dateien bleiben für eine unabhängige Frequenzprüfung erhalten.
"""
import argparse
import array
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True
import subprocess
import urllib.request


def integration():
    spec = importlib.util.spec_from_file_location('integration', Path(__file__).with_name('timeshift-integration.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(root):
    integration().prepare(root)
    shutil.copy(__file__, root / 'runner.py')
    shutil.copy(Path(__file__).with_name('timeshift-integration.py'), root / 'timeshift-integration.py')


def serve(root):
    integration().serve(root)


def cleanup(root):
    integration().common().cleanup(root)


def run(root, direct_only=False):
    helper = integration().common()
    ax = Path(os.environ['MUCKE_AX_TOOL'])
    server = subprocess.Popen([os.sys.executable, str(root / 'runner.py'), 'serve', str(root)])
    helper.track(root, server, 'server', root / 'runner.py')
    try:
        helper.wait(lambda: (root / 'server.json').exists())
        base = 'http://127.0.0.1:' + str(json.loads((root / 'server.json').read_text())['port'])
        contexts = [(language, True) for language in ['de', 'en']] if direct_only else [
            (language, direct) for direct in [False, True] for language in ['de', 'en']]
        for language, direct in contexts:
            target = root / (('direct-' if direct else '') + language)
            target.mkdir()
            for name in ['home', 'recordings', 'history', 'buffers']:
                (target / name).mkdir()
            sentinel = target / 'recordings/permanent-sentinel.mp3'
            sentinel.write_bytes(b'Existing recording')
            app = root / 'TimeshiftTransportProbe.app'
            launcher = subprocess.Popen(['open', '-n', '-W', str(app),
                '--env', 'CFFIXED_USER_HOME=' + str(target / 'home'), '--env', 'MUCKE_RECOGNITION_TRANSPORT=1',
                '--env', 'MUCKE_RECOGNITION_DIRECT_ONLY=' + ('1' if direct else '0'),
                '--env', 'MUCKE_RECOGNITION_CORE_ONLY=' + ('0' if direct else '1'),
                '--args', str(target), base + '/mp3', '-AppleLanguages', '(' + language + ')',
                '-AppleLocale', 'de_DE' if language == 'de' else 'en_US', '-volume', '0', '-recordStreams', 'NO'])
            helper.wait(lambda: (target / 'app.pid').exists(), target=target)
            pid = int((target / 'app.pid').read_text())
            (root / 'app.owned.json').write_text(json.dumps(dict(pid=pid, expected=str(app / 'Contents/MacOS/TimeshiftTransportProbe'))))

            def command(action, *args):
                return subprocess.check_output([str(ax), action, str(pid), *args], text=True, timeout=10)

            def mark(name, seconds=75):
                helper.wait(lambda: (target / (name + '.txt')).exists(), seconds, target)

            for codec in ([] if direct else ['mp3', 'aac', 'heaac']):
                mark(codec + '-recognize-ready', 140)
                command('press', 'recognition-open')
                command('press', 'recognition-start')
                mark(codec + '-result')
                (target / (codec + '-result-ax.json')).write_text(command('dump'))
                command('press', 'recognition-adopt')
                command('press', 'recognition-bookmark')
                mark(codec + '-adopted', 90)
                # Neu montierte Hauptansichten können das ursprüngliche Sheet
                # bereits geschlossen haben. Nur vorhandene Kennungen bedienen.
                dump = command('dump')
                if 'recognition-close' in dump:
                    command('press', 'recognition-close')
                command('press', 'timeshift-pause')
                mark(codec + '-paused')
                command('press', 'recognition-open')
                paused = command('dump')
                (target / (codec + '-paused-ax.json')).write_text(paused)
                message = 'Für die Erkennung muss Audio spielen.' if language == 'de' else 'Audio must be playing to identify music.'
                assert message in paused
                def nodes(node):
                    yield node
                    for child in node.get('children', []):
                        yield from nodes(child)
                start = next(node for node in nodes(json.loads(paused)) if node.get('AXIdentifier') == 'recognition-start')
                assert not start['AXEnabled']
                command('press', 'recognition-close')
                command('press', 'timeshift-pause')
            mark('recognition-passed', 180)
            assert launcher.wait(timeout=15) == 0
            assert sentinel.read_bytes() == b'Existing recording'
            assert not [p for p in (target / 'buffers').iterdir() if p.is_dir()]
            helper.wait(lambda: not json.load(urllib.request.urlopen(base + '/stats', timeout=5))['active'])
            (root / 'app.owned.json').unlink()
        if direct_only:
            verify_direct(root)
        else:
            verify(root)
    finally:
        cleanup(root)
        if server.poll() is None:
            server.terminate()
        server.wait(timeout=10)


def verify_core(root):
    result = []
    for language in ['de', 'en']:
        target = root / language
        stages = {entry['stage']: entry for entry in json.loads((target / 'observations.json').read_text())}
        history = json.loads((target / 'history/verlauf.json').read_text())
        def timestamp(value):
            return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
        for codec in ['mp3', 'aac', 'heaac']:
            assert not stages[codec + '-reconnected-held']['playing']
            for suffix in ['same-title-seek', 'live', 'station-restart', 'adopted']:
                assert codec + '-' + suffix in stages
            heard = stages[codec + '-adopted']
            received = [entry for entry in history if entry['station'] == 'Fixture • ' + codec
                        and timestamp(entry['start']) <= heard['at']
                        and (not entry.get('end') or heard['at'] < timestamp(entry['end']))]
            assert any('880' in entry['raw'] for entry in received), 'Fixture trennt Empfang und gehörten Ausschnitt nicht'
            assert '440' in heard['title'] and heard['position'] < 15
        assert stages['expired-held']['phase'] == 'expired' and not stages['expired-held']['playing']
        captures = sorted(target.glob('capture-*.f32'))
        assert len(captures) == 15 or (len(captures) == 18 and all(codec + '-direct' in stages for codec in ['vorbis', 'opus', 'flac']))
        captures = [file for file in captures if int(file.stem.split('-')[-1]) <= 15]
        assert len(captures) == 15, 'Unerwartete oder fehlende Erkennungsaufrufe'
        for file in captures:
            samples = array.array('f', file.read_bytes())
            assert 48_000 * 3 <= len(samples) <= 48_000 * 12
            # FFmpeg nutzt einen unabhängigen Bandpass-Analysepfad. Die Pegelwerte
            # beider Frequenzen trennen den gehörten Abschnitt vom Live-Empfang.
            peaks = []
            for frequency in [440, 880]:
                checked = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'f32le', '-ar', '48000', '-ac', '1',
                    '-i', str(file), '-af', f'bandpass=f={frequency}:width_type=h:w=20', '-f', 'f32le', '-'],
                    check=True, capture_output=True, timeout=20)
                filtered = array.array('f', checked.stdout)
                peaks.append(sum(x*x for x in filtered) / len(filtered))
            frequency = [440, 880][peaks.index(max(peaks))]
            result.append(dict(language=language, file=file.name, samples=len(samples), frequency=frequency, energies=peaks))
        bookmarks = json.loads((target / 'store/bookmarks.json').read_text())
        assert bookmarks['formatVersion'] == 3 and len(bookmarks['entries']) == 1
        entry = bookmarks['entries'][0]
        assert '440' in entry['raw'] and entry['recognition']['source'] == 'shazam'
        assert entry['recognition']['listening']['position'] < 15
        assert entry['recognition']['listening']['receivedAt'] < entry['heardAt'] < entry['recognition']['recognizedAt']
        first = next(row for row in result if row['language'] == language and row['file'] == 'capture-1.f32')
        assert first['frequency'] == 440
        for number in [1, 6, 11]:
            assert next(row for row in result if row['language'] == language and row['file'] == f'capture-{number}.f32')['frequency'] == 440
        assert len(list(target.glob('recognition-*.png'))) == 48
    (root / 'independent-check.json').write_text(json.dumps(result, indent=2))
    (root / 'core-result.json').write_text(json.dumps(dict(passed=True, languages=['de', 'en'], captures=len(result))))


def verify(root):
    verify_core(root)
    verify_direct(root)
    (root / 'result.json').write_text(json.dumps(dict(passed=True, coreCaptures=30, directCaptures=6)))


def run_direct(root):
    run(root, direct_only=True)


def verify_direct(root):
    results = []
    for language in ['de', 'en']:
        target = root / ('direct-' + language)
        stages = {entry['stage']: entry for entry in json.loads((target / 'observations.json').read_text())}
        captures = sorted(target.glob('capture-*.f32'))
        assert len(captures) == 3
        for codec in ['vorbis', 'opus', 'flac']:
            assert stages[codec + '-direct']['playing']
        for file in captures:
            pcm = array.array('f', file.read_bytes())
            assert 48_000 * 3 <= len(pcm) <= 48_000 * 12
            energies = []
            for frequency in [440, 880]:
                checked = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'f32le', '-ar', '48000', '-ac', '1',
                    '-i', str(file), '-af', f'bandpass=f={frequency}:width_type=h:w=20', '-f', 'f32le', '-'],
                    check=True, capture_output=True, timeout=20)
                filtered = array.array('f', checked.stdout)
                energies.append(sum(x*x for x in filtered) / len(filtered))
            assert energies[0] > energies[1] * 10
            results.append(dict(language=language, file=file.name, samples=len(pcm), energies=energies))
    (root / 'direct-result.json').write_text(json.dumps(dict(passed=True, captures=results), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'serve', 'run', 'run-direct', 'verify', 'verify-core', 'verify-direct', 'cleanup'])
    parser.add_argument('root', type=lambda value: Path(value).expanduser().resolve())
    args = parser.parse_args()
    globals()[args.mode.replace('-', '_')](args.root)
