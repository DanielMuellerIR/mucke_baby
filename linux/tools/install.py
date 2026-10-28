#!/usr/bin/env python3
"""Benutzerinstallation mit atomarem Austausch und Rücknahme bei Abbruch."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


def atomic_write(target, content, mode=0o644):
    fd, name = tempfile.mkstemp(prefix='.mucke-install-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(name, mode)
        os.replace(name, target)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def atomic_link(target, destination):
    fd, name = tempfile.mkstemp(prefix='.mucke-install-', dir=target.parent)
    os.close(fd)
    os.unlink(name)
    try:
        os.symlink(destination, name)
        os.replace(name, target)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def snapshot(target):
    try:
        info = target.lstat()
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode):
        return ('link', os.readlink(target), 0)
    if not stat.S_ISREG(info.st_mode) or info.st_size > 64 * 1024 * 1024:
        raise RuntimeError('Installationsziel ist keine reguläre Datei: ' + str(target))
    return ('file', target.read_bytes(), stat.S_IMODE(info.st_mode))


def restore(target, previous):
    if previous is None:
        with contextlib.suppress(FileNotFoundError):
            target.unlink()
    elif previous[0] == 'link':
        atomic_link(target, previous[1])
    else:
        atomic_write(target, previous[1], previous[2])


def version_of(binary):
    environment = dict(os.environ, QT_QPA_PLATFORM='offscreen')
    result = subprocess.run([str(binary), '--version'], env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=True, text=True, timeout=15)
    match = re.fullmatch(r'MuckeBaby ([0-9]+\.[0-9]+\.[0-9]+)\s*', result.stdout)
    if not match:
        raise RuntimeError('Die Versionsprüfung der App ist fehlgeschlagen.')
    return match.group(1)


def install(binary, prefix, source_root, publish=None):
    binary = Path(binary).resolve(strict=True)
    prefix = Path(prefix).expanduser().absolute()
    source_root = Path(source_root).resolve(strict=True)
    checkout = (source_root / 'linux/packaging').is_dir()
    licenses = source_root if checkout else source_root / 'share/doc/mucke-baby'
    packaging = source_root / 'linux/packaging' if checkout else source_root / 'share/applications'
    icon_source = source_root / 'icons/app-icon-s123.png' if checkout else source_root / 'share/icons/hicolor/1024x1024/apps/mucke-baby.png'
    if prefix == Path('/') or any(ord(c) < 32 for c in str(prefix)):
        raise RuntimeError('Ungültiger Installationspfad.')
    version = version_of(binary)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    app_root = prefix / 'lib/mucke-baby'
    app_root.mkdir(parents=True, exist_ok=True)
    # Ein zweiter Installer darf die Rücknahme des ersten nicht überholen.
    with (app_root / '.install.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        staged = Path(tempfile.mkdtemp(prefix='.install-', dir=app_root))
        installed = app_root / (version + '-' + digest[:16])
        created_version = False
        changed = []
        committed = False
        try:
            (staged / 'bin').mkdir()
            shutil.copy2(binary, staged / 'bin/mucke-baby')
            os.chmod(staged / 'bin/mucke-baby', 0o755)
            if version_of(staged / 'bin/mucke-baby') != version:
                raise RuntimeError('Die kopierte App hat eine andere Version.')
            for name in ('LICENSE', 'THIRD-PARTY.md'):
                shutil.copy2(licenses / name, staged / name)
            shutil.copy2((packaging if checkout else licenses) / 'nlohmann-json-LICENSE.MIT', staged / 'nlohmann-json-LICENSE.MIT')
            font_license = source_root / 'linux/resources/fonts/OFL.txt' if checkout else licenses / 'ZillaSlab-OFL.txt'
            shutil.copy2(font_license, staged / 'ZillaSlab-OFL.txt')
            (staged / 'manifest.json').write_text(json.dumps({
                'version': version, 'sha256': digest,
                'installedAt': datetime.now(timezone.utc).isoformat()
            }, indent=2) + '\n')
            if installed.exists():
                if installed.is_symlink() or hashlib.sha256((installed / 'bin/mucke-baby').read_bytes()).hexdigest() != digest:
                    raise RuntimeError('Ein vorhandener Versionsordner stimmt nicht mit dem Build überein.')
            else:
                staged.rename(installed)
                created_version = True
            launcher = prefix / 'bin/mucke-baby'
            desktop = prefix / 'share/applications/de.danielmuller.muckebaby.desktop'
            icon = prefix / 'share/icons/hicolor/1024x1024/apps/mucke-baby.png'
            for target in (launcher, desktop, icon):
                target.parent.mkdir(parents=True, exist_ok=True)
            executable = str(launcher).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
            # Manche Symbol-Themes kennen keine 1024er-Verzeichnisse; der direkte Pfad bleibt auflösbar.
            icon_value = str(icon).replace('\\', '\\\\')
            desktop_bytes = (packaging / 'de.danielmuller.muckebaby.desktop').read_text().replace('Exec=mucke-baby', 'Exec="' + executable + '"').replace('Icon=mucke-baby', 'Icon=' + icon_value).encode()
            actions = [
                (launcher, lambda: atomic_link(launcher, str(installed / 'bin/mucke-baby'))),
                (desktop, lambda: atomic_write(desktop, desktop_bytes)),
                (icon, lambda: atomic_write(icon, icon_source.read_bytes()))
            ]
            for index, (target, action) in enumerate(actions):
                old = snapshot(target)
                # Der Übergang wird vor dem Tausch erfasst; auch ein Signal direkt danach ist rücknehmbar.
                changed.append((target, old))
                action()
                if publish is not None:
                    publish(index, target)
            if version_of(launcher) != version or hashlib.sha256(launcher.read_bytes()).hexdigest() != digest:
                raise RuntimeError('Die Abschlussprüfung der installierten App ist fehlgeschlagen.')
            committed = True
            return {'binary': str(launcher), 'version': version, 'sha256': digest, 'directory': str(installed)}
        finally:
            if not committed:
                failures = []
                for target, old in reversed(changed):
                    try:
                        restore(target, old)
                    except BaseException as error:
                        failures.append(str(error))
                if created_version and not failures:
                    shutil.rmtree(installed)
                if failures:
                    raise RuntimeError('Installationsrücknahme unvollständig: ' + '; '.join(failures))
            if staged.exists():
                shutil.rmtree(staged)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--source-root', required=True)
    args = parser.parse_args()
    def interrupted(number, _frame):
        raise InterruptedError('Installation durch Signal ' + str(number) + ' abgebrochen.')
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGPIPE):
        signal.signal(number, interrupted)
    result = install(args.binary, args.prefix, args.source_root)
    cache = shutil.which('update-desktop-database')
    if cache:
        completed = subprocess.run([cache, str(Path(args.prefix) / 'share/applications')], check=False)
        if completed.returncode:
            print('Hinweis: Desktop-Cache konnte nicht aktualisiert werden.', file=sys.stderr)
    kde_cache = shutil.which('kbuildsycoca6')
    if kde_cache and 'kde' in os.environ.get('XDG_CURRENT_DESKTOP', '').lower():
        try:
            completed = subprocess.run([kde_cache, '--noincremental'],
                                       env=dict(os.environ, QT_QPA_PLATFORM='offscreen'),
                                       check=False, timeout=30)
            if completed.returncode:
                print('Hinweis: KDE-Anwendungsmenü konnte nicht aktualisiert werden.', file=sys.stderr)
        except subprocess.TimeoutExpired:
            print('Hinweis: KDE-Anwendungsmenü konnte nicht aktualisiert werden.', file=sys.stderr)
    print('INSTALL OK: ' + result['binary'] + ' (' + result['version'] + ')')

if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('Installation fehlgeschlagen: ' + str(error), file=sys.stderr)
        sys.exit(1)
