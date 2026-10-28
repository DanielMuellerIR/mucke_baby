#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import os
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('mucke_install', Path(__file__).parents[1] / 'tools/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mucke-installer-test-')
        self.root = Path(self.temporary.name)
        self.prefix = self.root / 'home with spaces/.local'
        self.source = self.root / 'source'
        (self.source / 'linux/packaging').mkdir(parents=True)
        (self.source / 'icons').mkdir()
        (self.source / 'LICENSE').write_text('MIT fixture')
        (self.source / 'linux/packaging/nlohmann-json-LICENSE.MIT').write_text('JSON MIT fixture')
        (self.source / 'THIRD-PARTY.md').write_text('Licenses fixture')
        (self.source / 'linux/packaging/de.danielmuller.muckebaby.desktop').write_text('[Desktop Entry]\nExec=mucke-baby\n')
        (self.source / 'icons/app-icon-s123.png').write_bytes(b'icon fixture')
        self.binary = self.root / 'build/mucke-baby'
        self.binary.parent.mkdir()
        self.make_binary('1.2.3')

    def tearDown(self):
        self.temporary.cleanup()

    def make_binary(self, version):
        self.binary.write_text('#!/bin/sh\necho "MuckeBaby ' + version + '"\n')
        self.binary.chmod(0o755)

    def test_first_install_is_complete_and_versioned(self):
        result = installer.install(self.binary, self.prefix, self.source)
        launcher = self.prefix / 'bin/mucke-baby'
        self.assertTrue(launcher.is_symlink())
        self.assertEqual(launcher.read_bytes(), self.binary.read_bytes())
        self.assertEqual(result['version'], '1.2.3')
        self.assertIn('Exec="', (self.prefix / 'share/applications/de.danielmuller.muckebaby.desktop').read_text())
        self.assertTrue((Path(result['directory']) / 'LICENSE').exists())

    def test_first_install_failure_leaves_no_app(self):
        def fail(_index, _target):
            raise RuntimeError('controlled failure')
        with self.assertRaisesRegex(RuntimeError, 'controlled'):
            installer.install(self.binary, self.prefix, self.source, fail)
        self.assertFalse((self.prefix / 'bin/mucke-baby').exists())
        self.assertFalse((self.prefix / 'bin/mucke-baby').is_symlink())
        self.assertEqual(list((self.prefix / 'lib/mucke-baby').glob('1.*')), [])

    def test_failed_update_restores_all_previous_targets(self):
        original = installer.install(self.binary, self.prefix, self.source)
        launcher = self.prefix / 'bin/mucke-baby'
        desktop = self.prefix / 'share/applications/de.danielmuller.muckebaby.desktop'
        icon = self.prefix / 'share/icons/hicolor/1024x1024/apps/mucke-baby.png'
        before = [installer.snapshot(target) for target in (launcher, desktop, icon)]
        self.make_binary('1.2.4')
        def fail(index, _target):
            if index == 1:
                raise InterruptedError('controlled interruption')
        with self.assertRaises(InterruptedError):
            installer.install(self.binary, self.prefix, self.source, fail)
        self.assertEqual([installer.snapshot(target) for target in (launcher, desktop, icon)], before)
        self.assertEqual(installer.version_of(launcher), '1.2.3')
        self.assertTrue(Path(original['directory']).exists())
        self.assertEqual(list((self.prefix / 'lib/mucke-baby').glob('1.2.4-*')), [])

    def test_successful_update_preserves_previous_version(self):
        original = installer.install(self.binary, self.prefix, self.source)
        self.make_binary('1.2.4')
        updated = installer.install(self.binary, self.prefix, self.source)
        self.assertNotEqual(original['directory'], updated['directory'])
        self.assertTrue(Path(original['directory']).exists())
        self.assertEqual(installer.version_of(self.prefix / 'bin/mucke-baby'), '1.2.4')

    def test_foreign_directory_target_is_preserved(self):
        foreign = self.prefix / 'share/applications/de.danielmuller.muckebaby.desktop'
        foreign.mkdir(parents=True)
        (foreign / 'keep').write_text('preserve')
        with self.assertRaises(RuntimeError):
            installer.install(self.binary, self.prefix, self.source)
        self.assertEqual((foreign / 'keep').read_text(), 'preserve')
        self.assertFalse((self.prefix / 'bin/mucke-baby').is_symlink())

    def test_reinstall_same_build_keeps_version_directory(self):
        first = installer.install(self.binary, self.prefix, self.source)
        second = installer.install(self.binary, self.prefix, self.source)
        self.assertEqual(first['directory'], second['directory'])
        self.assertEqual(list((self.prefix / 'lib/mucke-baby').glob('.install-*')), [])


if __name__ == '__main__':
    unittest.main()
