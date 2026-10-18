#!/usr/bin/env python3
"""Native Frame-Seek-Gegenprobe; run nur in einer exklusiven Ressourcen-FIFO.

prepare ROOT erzeugt einen frischen isolierten Prüfstand, run ROOT dekodiert,
verify ROOT vergleicht jeden Ausgabesample mit unabhängiger Dateiwiedergabe.
"""
import argparse
import array
import json
import os
from pathlib import Path
import shutil
import subprocess


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    framework = repo / '.vendor/VLCKit.xcframework/macos-arm64_x86_64'
    subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos14.2', '-module-cache-path', str(repo / 'build/module-cache'),
        '-F', str(framework), '-framework', 'VLCKit', *[str(repo / 'Sources' / (n + '.swift')) for n in ['MetadataTimeline', 'TimeshiftBuffer', 'TimeshiftSegments']],
        str(repo / 'Tests/TimeshiftSeekHarness.swift'), '-o', str(root / 'decode')], check=True, timeout=120)
    shutil.copytree(framework / 'VLCKit.framework', root / 'VLCKit.framework', symlinks=True)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(root / 'VLCKit.framework')], check=True, timeout=60)
    for name, rate, channels, codec in [('cbr', 48000, 2, ['-b:a', '128k']), ('vbr', 44100, 2, ['-q:a', '3']), ('mpeg2', 24000, 1, ['-b:a', '64k']),
            ('mpeg1-32k', 32000, 2, ['-b:a', '96k']), ('mpeg2-16k', 16000, 1, ['-b:a', '32k']), ('mpeg25-8k', 8000, 1, ['-b:a', '16k'])]:
        folder = root / name
        folder.mkdir()
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'sine=frequency=523:sample_rate={rate}:duration=12', '-ac', str(channels),
            '-c:a', 'libmp3lame', *codec, '-write_xing', '0', '-id3v2_version', '0', str(folder / 'source.mp3')], check=True, timeout=60)
    shutil.copy(__file__, root / 'runner.py')


def run(root):
    assert not (root / 'native.txt').exists()
    subprocess.run([str(root / 'decode'), str(root)], env=dict(os.environ, DYLD_FRAMEWORK_PATH=str(root)), check=True, timeout=540)
    assert (root / 'native.txt').read_text() == 'passed'
    verify(root)


def verify(root):
    controls = {}
    results = []
    for entry in json.loads((root / 'seeks.json').read_text()):
        name = entry['case']
        def pcm(file):
            checked = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(file), '-f', 'f32le', '-'], capture_output=True, check=True, timeout=30)
            assert not checked.stderr
            return checked.stdout
        if name not in controls:
            controls[name] = pcm(root / name / 'control.wav')
        actual = pcm(root / entry['output'])
        expected = controls[name][entry['offsetSamples'] * 4:]
        assert len(actual) == len(expected), f'Falscher Einstieg oder Dauer: {entry}'
        a, b = array.array('f', actual), array.array('f', expected)
        difference = max(abs(x - y) for x, y in zip(a, b))
        assert difference < 0.000001, f'PCM-Abweichung einschließlich erster Ausgabesamples: {entry}'
        results.append(dict(entry, samples=len(a), maxDifference=difference, pcmEqual=actual == expected))
    assert len(results) == 24
    (root / 'independent-check.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'run', 'verify'])
    parser.add_argument('root', type=lambda value: Path(value).expanduser().resolve())
    args = parser.parse_args()
    globals()[args.mode](args.root)
