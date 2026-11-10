#!/usr/bin/env python3
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'tools'))
import update
import install as installer


class UpdateTests(unittest.TestCase):
    def release(self, version='1.10.5', **asset_changes):
        name = f'mucke-baby-{version}-linux-x86_64.tar.gz'
        asset = {'name': name, 'size': 123, 'digest': 'sha256:' + 'a' * 64,
                 'browser_download_url': f'https://github.com/{update.REPOSITORY}/releases/download/v{version}/{name}'}
        asset.update(asset_changes)
        return {'tag_name': 'v' + version, 'draft': False, 'prerelease': False, 'assets': [asset]}

    def check(self, releases, current='1.10.4'):
        return update.check(current, lambda _: io.BytesIO(json.dumps(releases).encode()))

    def test_selects_linux_when_newest_release_is_only_for_macos(self):
        mac = self.release('1.12.0'); mac['assets'] = []
        result = self.check([mac, self.release('1.10.5'), self.release('1.9.99')])
        self.assertTrue(result['available'])
        self.assertEqual(result['version'], '1.10.5')

    def test_no_downgrade_or_missing_digest_or_foreign_download(self):
        for release in [self.release('1.10.4'), self.release('1.9.9'), self.release(digest=None),
                        self.release(browser_download_url='https://evil.example/update.tar.gz'),
                        self.release(size=update.MAX_ARCHIVE + 1)]:
            self.assertFalse(self.check([release])['available'])
        for field in ('draft', 'prerelease'):
            release = self.release(); release[field] = True
            self.assertFalse(self.check([release])['available'])

    def test_corrupt_or_truncated_download_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = self.check([self.release()])
            for index, data in enumerate((b'broken', b'x' * 124)):
                with self.assertRaises(ValueError):
                    update.download(candidate, Path(directory) / str(index), lambda _: io.BytesIO(data))

    def archive(self, entries):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            for path, content, kind in entries:
                entry = tarfile.TarInfo(path)
                entry.type = kind; entry.size = len(content)
                if kind == tarfile.SYMTYPE: entry.linkname = '/tmp/outside'
                archive.addfile(entry, io.BytesIO(content))
        return data.getvalue()

    def test_archive_cannot_escape_or_link_or_overwrite(self):
        root = 'mucke-baby-1.10.5-linux-x86_64'
        for entries in [ [('..' + '/outside', b'x', tarfile.REGTYPE)],
                         [(root + '/../outside', b'x', tarfile.REGTYPE)],
                         [(root + '/link', b'', tarfile.SYMTYPE)],
                         [(root + '/file', b'x', tarfile.REGTYPE)] * 2 ]:
            with tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / 'archive'; archive.write_bytes(self.archive(entries))
                with self.assertRaises(ValueError):
                    update.unpack(archive, Path(directory) / 'unpacked', root + '.tar.gz')
                self.assertFalse((Path(directory) / 'outside').exists())

    def test_verified_download_installs_atomically_without_touching_user_data(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory); old = directory / 'old'; old.mkdir()
            docs = old / 'share/doc/mucke-baby'; docs.mkdir(parents=True)
            for name in ('LICENSE', 'THIRD-PARTY.md', 'nlohmann-json-LICENSE.MIT', 'ZillaSlab-OFL.txt'):
                (docs / name).write_text('Fixture license')
            desktop = old / 'share/applications'; desktop.mkdir(parents=True)
            (desktop / 'de.danielmuller.muckebaby.desktop').write_text('[Desktop Entry]\nExec=mucke-baby\nIcon=mucke-baby\n')
            icon = old / 'share/icons/hicolor/1024x1024/apps'; icon.mkdir(parents=True)
            (icon / 'mucke-baby.png').write_bytes(b'fixture')
            binary = old / 'bin/mucke-baby'; binary.parent.mkdir()
            binary.write_text('#!/bin/sh\necho "MuckeBaby 1.10.4"\n'); binary.chmod(0o755)
            prefix = directory / 'prefix with spaces'
            first = installer.install(binary, prefix, old)
            protected = directory / 'user-data.json'; protected.write_text('keep me')
            root = 'mucke-baby-1.10.5-linux-x86_64'
            entries = [(root + '/' + str(path.relative_to(old)), path.read_bytes(), tarfile.REGTYPE)
                       for path in old.rglob('*') if path.is_file() and path != binary]
            entries.append((root + '/bin/mucke-baby', b'#!/bin/sh\necho "MuckeBaby 1.10.5"\n', tarfile.REGTYPE))
            package = self.archive(entries)
            candidate = self.check([self.release(size=len(package), digest='sha256:' + hashlib.sha256(package).hexdigest())])
            result = update.install_update(candidate, first['directory'] + '/bin/mucke-baby', '1.10.4', lambda _: io.BytesIO(package))
            self.assertEqual(result['version'], '1.10.5')
            self.assertTrue(result['installed'])
            self.assertEqual(installer.version_of(prefix / 'bin/mucke-baby'), '1.10.5')
            self.assertEqual(protected.read_text(), 'keep me')
            self.assertTrue(Path(first['directory']).exists())
            with self.assertRaises(ValueError):
                update.install_target(first['directory'] + '/bin/mucke-baby', '1.10.4')

    def test_failure_keeps_previous_launcher(self):
        # Der eigentliche atomare Installations-Rollback wird zusätzlich von installer_test.py geprüft.
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'launcher'; target.write_text('old version')
            candidate = self.check([self.release()])
            with patch.object(update, 'install_target', return_value=Path(directory)):
                with self.assertRaises(ValueError):
                    update.install_update(candidate, target, '1.10.4', lambda _: io.BytesIO(b'corrupt'))
            self.assertEqual(target.read_text(), 'old version')


if __name__ == '__main__':
    unittest.main()
