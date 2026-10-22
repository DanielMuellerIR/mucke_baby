#!/usr/bin/env python3
"""Headless-Gegenproben für die unabhängige Audioauswertung, ohne Appstart."""
import array
import importlib.util
import json
import math
from pathlib import Path
import random
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('recognition', Path(__file__).with_name('timeshift-recognition.py'))
recognition = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recognition)


class ToneChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='MuckeToneChecks-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def pcm(self, frequency, amplitude=0.1):
        return array.array('f', (amplitude * math.sin(2 * math.pi * frequency * index / 48_000)
                                 for index in range(48_000 * 3)))

    def direct_fixture(self, frequency):
        for language in ['de', 'en']:
            target = self.root / ('direct-' + language)
            target.mkdir()
            (target / 'observations.json').write_text(json.dumps([
                dict(stage=codec + '-direct', playing=True) for codec in ['vorbis', 'opus', 'flac']]))
            for number in range(1, 4):
                (target / f'capture-{number}.f32').write_bytes(self.pcm(frequency).tobytes())

    def test_direct_rejects_halved_frequency(self):
        self.direct_fixture(220)
        with self.assertRaises(AssertionError):
            recognition.verify_direct(self.root)
        self.assertFalse((self.root / 'direct-result.json').exists())

    def test_direct_accepts_expected_tone(self):
        self.direct_fixture(440)
        recognition.verify_direct(self.root)
        self.assertTrue(json.loads((self.root / 'direct-result.json').read_text())['passed'])

    def test_direct_rejects_other_fixture_tone(self):
        self.direct_fixture(880)
        with self.assertRaises(AssertionError):
            recognition.verify_direct(self.root)

    def test_expected_tones(self):
        for frequency in [440, 880]:
            for amplitude in [0.1, 0.005]:
                with self.subTest(frequency=frequency, amplitude=amplitude):
                    file = self.root / 'tone.f32'
                    file.write_bytes(self.pcm(frequency, amplitude).tobytes())
                    result = recognition.analyze_capture(file)
                    self.assertEqual(result['frequency'], frequency)
                    self.assertGreaterEqual(max(result['energies']) / result['totalEnergy'], 0.8)

    def test_wrong_audio(self):
        generator = random.Random(42)
        signals = {str(frequency): self.pcm(frequency) for frequency in [110, 220, 660, 1760]}
        signals['silence'] = self.pcm(0)
        signals['DC'] = array.array('f', [0.1]) * (48_000 * 3)
        signals['noise'] = array.array('f', (generator.uniform(-0.1, 0.1) for _ in range(48_000 * 3)))
        signals['nonfinite'] = array.array('f', [float('nan')]) * (48_000 * 3)
        signals['short'] = self.pcm(440)[:48_000]
        for name, samples in signals.items():
            with self.subTest(signal=name):
                file = self.root / 'wrong.f32'
                file.write_bytes(samples.tobytes())
                with self.assertRaises(AssertionError):
                    recognition.analyze_capture(file)


if __name__ == '__main__':
    unittest.main()
