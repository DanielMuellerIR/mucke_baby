#!/usr/bin/env python3
"""GitHub-Updates prüfen und nach Bestätigung atomar im Benutzerpräfix installieren."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import sys
import tarfile
import tempfile
import urllib.request
from urllib.parse import urlsplit

REPOSITORY = 'DanielMuellerIR/mucke_baby'
API = 'https://api.github.com/repos/' + REPOSITORY + '/releases?per_page=30'
MAX_ARCHIVE = 128 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}', value):
        raise ValueError('Ungültige Versionsnummer / invalid version')
    return tuple(map(int, value.split('.')))


class SecureRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urlsplit(newurl)
        if (url.scheme != 'https' or url.username or url.password or url.port not in (None, 443)
                or url.hostname not in ('github.com', 'api.github.com',
                                        'release-assets.githubusercontent.com', 'objects.githubusercontent.com')):
            raise ValueError('Unsichere Download-Weiterleitung / unsafe download redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_url(url):
    request = urllib.request.Request(url, headers={
        'User-Agent': 'MuckeBaby-Linux-Updater', 'Accept': 'application/vnd.github+json'})
    return urllib.request.build_opener(SecureRedirect()).open(request, timeout=20)


def check(current, fetch=open_url):
    installed = version_tuple(current)
    with fetch(API) as response:
        raw = response.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('Release-Antwort zu groß / release response too large')
    releases = json.loads(raw)
    if not isinstance(releases, list):
        raise ValueError('Ungültige Release-Antwort / invalid release response')
    candidates = []
    for release in releases:
        if not isinstance(release, dict) or release.get('draft') is not False or release.get('prerelease') is not False:
            continue
        tag = release.get('tag_name', '')
        if not isinstance(tag, str) or not tag.startswith('v'):
            continue
        version = tag[1:]
        try:
            newer = version_tuple(version) > installed
        except ValueError:
            continue
        if not newer:
            continue
        name = f'mucke-baby-{version}-linux-x86_64.tar.gz'
        expected_url = f'https://github.com/{REPOSITORY}/releases/download/{tag}/{name}'
        assets = release.get('assets', [])
        if not isinstance(assets, list):
            continue
        for asset in assets:
            if (not isinstance(asset, dict) or asset.get('name') != name
                    or asset.get('browser_download_url') != expected_url
                    or not isinstance(asset.get('size'), int) or not 0 < asset['size'] <= MAX_ARCHIVE
                    or not re.fullmatch(r'sha256:[0-9a-f]{64}', str(asset.get('digest', '')))):
                continue
            candidates.append({'version': version, 'url': expected_url, 'size': asset['size'],
                               'sha256': asset['digest'][7:], 'name': name})
    if not candidates:
        return {'available': False, 'current': current}
    candidate = max(candidates, key=lambda item: version_tuple(item['version']))
    return dict(candidate, available=True, current=current)


def download(candidate, target, fetch=open_url):
    digest = hashlib.sha256()
    size = 0
    with fetch(candidate['url']) as response, Path(target).open('xb') as output:
        while True:
            block = response.read(64 * 1024)
            if not block:
                break
            size += len(block)
            if size > candidate['size'] or size > MAX_ARCHIVE:
                raise ValueError('Download zu groß / download too large')
            digest.update(block)
            output.write(block)
    if size != candidate['size'] or digest.hexdigest() != candidate['sha256']:
        raise ValueError('Prüfsumme stimmt nicht / checksum mismatch')


def unpack(archive, destination, name):
    root_name = name.removesuffix('.tar.gz')
    seen = set()
    total = 0
    with tarfile.open(archive, 'r:gz') as package:
        for count, member in enumerate(package, 1):
            relative = PurePosixPath(member.name)
            if (count > 512 or relative.is_absolute() or '..' in relative.parts
                    or not relative.parts or relative.parts[0] != root_name
                    or '\\' in member.name or str(relative) in seen
                    or not (member.isdir() or member.isfile())):
                raise ValueError('Ungültiger Archivpfad / invalid archive entry')
            seen.add(str(relative))
            total += member.size
            if member.size < 0 or member.size > MAX_ARCHIVE or total > MAX_EXPANDED:
                raise ValueError('Entpacktes Archiv zu groß / expanded archive too large')
            target = Path(destination).joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output, 64 * 1024)
                target.chmod(0o755 if relative.as_posix() == root_name + '/bin/mucke-baby' else 0o644)
    return Path(destination) / root_name


def install_target(executable, current):
    binary = Path(executable).resolve(strict=True)
    if len(binary.parents) < 5 or binary.parent.name != 'bin' or binary.name != 'mucke-baby':
        raise ValueError('Keine Benutzerinstallation / not a user installation')
    version_dir = binary.parent.parent
    prefix = version_dir.parent.parent.parent
    if (version_dir.parent.name != 'mucke-baby' or version_dir.parent.parent.name != 'lib'
            or not (prefix / 'bin/mucke-baby').is_symlink()
            or (prefix / 'bin/mucke-baby').resolve() != binary):
        raise ValueError('Installation zuerst mit install.sh einrichten / run install.sh first')
    manifest = json.loads((version_dir / 'manifest.json').read_text())
    if manifest.get('version') != current or manifest.get('sha256') != hashlib.sha256(binary.read_bytes()).hexdigest():
        raise ValueError('Installierte Version verändert / installed version changed')
    if binary.stat().st_uid != os.getuid() or not os.access(prefix / 'bin', os.W_OK):
        raise ValueError('Installation nicht beschreibbar / installation not writable')
    return prefix


def install_update(candidate, executable, current, fetch=open_url):
    import install as installer
    prefix = install_target(executable, current)
    with tempfile.TemporaryDirectory(prefix='mucke-update-') as temporary:
        temporary = Path(temporary)
        archive = temporary / 'release.tar.gz'
        download(candidate, archive, fetch)
        root = unpack(archive, temporary / 'unpacked', candidate['name'])
        binary = root / 'bin/mucke-baby'
        if installer.version_of(binary) != candidate['version']:
            raise ValueError('Paketversion stimmt nicht / package version mismatch')
        result = installer.install(binary, prefix, root)
    return dict(result, installed=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--current', required=True)
    parser.add_argument('--install-version')
    parser.add_argument('--executable')
    args = parser.parse_args()
    def interrupted(number, _frame):
        raise InterruptedError('Update unterbrochen / update interrupted: ' + str(number))
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGPIPE):
        signal.signal(number, interrupted)
    candidate = check(args.current)
    if args.install_version:
        version_tuple(args.install_version)
        if not candidate['available'] or candidate['version'] != args.install_version or not args.executable:
            raise ValueError('Release geändert; erneut prüfen / release changed; check again')
        candidate = install_update(candidate, args.executable, args.current)
    print(json.dumps(candidate))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)
