#!/usr/bin/env python3
"""Veröffentlichungsziel und Tag-Grenzen ohne Netzwerk prüfen."""
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "wrappers/sign-and-release.sh").read_text()
preflight = source[source.index('  PUSH_URLS='):source.index('  # Ein veröffentlichtes DMG')]
publish = source[source.index('  git -C "$PROJECT_ROOT" push --no-follow-tags'):source.index('  # Veroeffentlichte Release-Dateien')]

with tempfile.TemporaryDirectory(prefix="mucke-publish-test-") as temporary:
    work = Path(temporary) / "work"
    remote = Path(temporary) / "remote.git"
    subprocess.run(["git", "init", "-q", str(work)], check=True)
    subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)

    def git(*args):
        return subprocess.run(["git", "-C", str(work), *args], check=True, capture_output=True, text=True).stdout.strip()

    git("config", "user.name", "Release Fixture")
    git("config", "user.email", "fixture@example.com")
    git("commit", "--allow-empty", "-m", "fixture")
    git("remote", "add", "github", "https://github.com/DanielMuellerIR/mucke_baby.git")
    prefix = "set -euo pipefail\nPROJECT_ROOT=" + shlex.quote(str(work)) + "\n"
    for url, expected in [
        ("https://github.com/DanielMuellerIR/mucke_baby.git", 0),
        ("git@github.com:DanielMuellerIR/mucke_baby.git", 0),
        ("https://github.com/example/other.git", 1),
        ("https://example.com/DanielMuellerIR/mucke_baby.git", 1),
    ]:
        git("remote", "set-url", "github", url)
        result = subprocess.run(["bash", "-c", prefix + preflight], capture_output=True, text=True)
        assert result.returncode == expected, result.stderr
    git("remote", "set-url", "github", "https://github.com/DanielMuellerIR/mucke_baby.git")
    git("config", "--add", "remote.github.pushurl", "https://github.com/DanielMuellerIR/mucke_baby.git")
    git("config", "--add", "remote.github.pushurl", "https://github.com/example/other.git")
    assert subprocess.run(["bash", "-c", prefix + preflight], capture_output=True).returncode != 0

    git("config", "push.followTags", "true")
    git("tag", "-a", "unrelated", "-m", "must stay local")
    git("tag", "-a", "v1.8.9", "-m", "release")
    git("branch", "v1.8.9")
    script = prefix + "TAG=v1.8.9\nPUSH_URL=" + shlex.quote(str(remote)) + "\n" + publish
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    refs = subprocess.check_output(["git", "--git-dir", str(remote), "for-each-ref", "--format=%(refname)"], text=True).splitlines()
    assert refs == ["refs/tags/v1.8.9"], refs
    assert git("rev-parse", "refs/tags/v1.8.9") == subprocess.check_output(
        ["git", "--git-dir", str(remote), "rev-parse", "refs/tags/v1.8.9"], text=True).strip()

print("ReleasePublishHarness: OK")
