#!/usr/bin/env python3
"""Native Frame-Seek-Gegenprobe; run nur in einer exklusiven Ressourcen-FIFO.

prepare ROOT erzeugt einen frischen isolierten Prüfstand, run ROOT dekodiert,
verify ROOT vergleicht jeden Ausgabesample mit unabhängiger Dateiwiedergabe.
"""
import argparse
import array
import json
import math
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
    profiles = []
    for name, rate, channels, codec in [('cbr', 48000, 2, ['-b:a', '128k']), ('vbr', 44100, 2, ['-q:a', '3']), ('mpeg2', 24000, 1, ['-b:a', '64k']),
            ('mpeg1-32k', 32000, 2, ['-b:a', '96k']), ('mpeg2-16k', 16000, 1, ['-b:a', '32k']), ('mpeg25-8k', 8000, 1, ['-b:a', '16k'])]:
        folder = root / name
        folder.mkdir()
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'sine=frequency=523:sample_rate={rate}:duration=12', '-ac', str(channels),
            '-c:a', 'libmp3lame', *codec, '-write_xing', '0', '-id3v2_version', '0', str(folder / 'source.mp3')], check=True, timeout=60)
        profiles.append(dict(name=name, codec='mp3', sampleRate=rate))
    for name, rate, channels in [('aac-48k', 48000, 2), ('aac-44k', 44100, 1), ('aac-16k', 16000, 1), ('aac-96k', 96000, 2)]:
        folder = root / name
        folder.mkdir()
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'aevalsrc=0.12*sin(2*PI*(220*t+37*t*t)):s={rate}:d=12',
            '-ac', str(channels), '-c:a', 'aac', '-b:a', '128k', '-f', 'adts', str(folder / 'source.aac')], check=True, timeout=60)
        profiles.append(dict(name=name, codec='aac', sampleRate=rate))
    wave = root / 'he-source.wav'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'aevalsrc=0.12*sin(2*PI*(220*t+37*t*t)):s=48000:d=12', '-ac', '2', str(wave)], check=True, timeout=30)
    for name, codec, bitrate, rate in [('heaac-48k', 'aach', 48000, 48000), ('heaacv2-48k', 'aacp', 32000, 48000),
                                      ('heaac-44k', 'aach', 48000, 44100), ('heaacv2-44k', 'aacp', 32000, 44100)]:
        folder = root / name
        folder.mkdir()
        subprocess.run(['afconvert', '-f', 'adts', '-d', codec + '@' + str(rate), '-b', str(bitrate), str(wave), str(folder / 'source.aac')], check=True, timeout=60)
        profiles.append(dict(name=name, codec='aac', sampleRate=rate))
    (root / 'profiles.json').write_text(json.dumps(profiles, indent=2))
    shutil.copy(__file__, root / 'runner.py')


def run(root):
    assert not (root / 'native.txt').exists()
    subprocess.run([str(root / 'decode'), str(root)], env=dict(os.environ, DYLD_FRAMEWORK_PATH=str(root)), check=True, timeout=1100)
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
            if 'inputFrameCount' in entry:
                assert len(controls[name]) == (entry['inputFrameCount'] - entry['primingFrames']) * entry['samplesPerFrame'] * 4
        actual = pcm(root / entry['output'])
        expected = controls[name][entry['offsetSamples'] * 4:]
        assert len(actual) == len(expected), f'Falscher Einstieg oder Dauer: {entry}'
        a, b = array.array('f', actual), array.array('f', expected)
        difference = max(abs(x - y) for x, y in zip(a, b))
        rms = math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)) / len(a))
        signal = math.sqrt(sum(y * y for y in b) / len(b))
        snr = 20 * math.log10(signal / max(rms, 1e-15))
        # HE-AAC ist nach einem Decoderneustart nicht bitgleich. Höchstens vier
        # 16-Bit-Stufen Spitze und mindestens 70 dB SNR erlauben diese Restabweichung;
        # Länge, Marker und erste Samples bleiben in derselben Gegenprobe.
        if name.startswith('he'):
            valid = difference < 4 / 32768 and snr > 70
        else:
            peak_limit = 0.00001 if name.startswith('aac') else 0.000001
            valid = difference < peak_limit and rms < 0.000001
        assert valid, f'PCM-Abweichung einschließlich erster Ausgabesamples: {entry}'
        first = entry.get('samplesPerFrame', 2048 if name.startswith('he') else 1024)
        first_difference = max(abs(x - y) for x, y in zip(a[:first], b[:first]))
        results.append(dict(entry, samples=len(a), maxDifference=difference, firstFrameDifference=first_difference,
                            rmsDifference=rms, snrDB=snr, pcmEqual=actual == expected))
    assert len(results) == 4 * len(json.loads((root / 'profiles.json').read_text()))
    (root / 'independent-check.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'run', 'verify'])
    parser.add_argument('root', type=lambda value: Path(value).expanduser().resolve())
    args = parser.parse_args()
    globals()[args.mode](args.root)
