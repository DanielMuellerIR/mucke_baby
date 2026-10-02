#!/usr/bin/env python3
"""DMG-Mount-Lebenszyklus mit gemocktem hdiutil ausschließlich in Temp prüfen."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "wrappers/sign-and-release.sh").read_text()
section = source[source.index('# ---------- 4. DMG'):source.index('echo "==> Signiere DMG"')]

with tempfile.TemporaryDirectory(prefix="mucke-release-test-") as temporary:
    fixture = Path(temporary)
    mock = fixture / "hdiutil"
    mock.write_text("""#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ['MOUNT_TEST_ROOT']).resolve()
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\\n')
if args[0] in ('attach', 'detach'):
    path = Path(args[args.index('-mountpoint') + 1] if args[0] == 'attach' else args[1]).resolve()
    if root not in path.parents:
        raise SystemExit('Mount außerhalb der Fixture abgewiesen')
    if args[0] == 'detach':
        shutil.rmtree(path)
        path.mkdir()
elif args[0] == 'create':
    Path(args[-1]).touch()
elif args[0] == 'convert':
    Path(args[args.index('-o') + 1]).touch()
else:
    raise SystemExit('Unerwarteter hdiutil-Aufruf')
""")
    mock.chmod(0o755)
    app = fixture / "Fixture.app"
    app.mkdir()
    background = fixture / "background.png"
    background.write_bytes(b"fixture")
    foreign = fixture / "already-mounted"
    foreign.write_bytes(b"unchanged")
    environment = dict(os.environ, PATH=f"{fixture}:{os.environ['PATH']}",
                       TMPDIR=str(fixture), MOUNT_TEST_ROOT=str(fixture))
    for abort in (False, True):
        calls = fixture / "calls.jsonl"
        calls.unlink(missing_ok=True)
        variables = {"APP_BUNDLE": str(app), "DMG_PATH": str(fixture / "out.dmg"),
                     "RW_DMG_PATH": str(fixture / "rw.dmg"), "BACKGROUND_SRC": str(background),
                     "VOLNAME": "MuckeBaby-Mount-Fixture", "FINDER_LAYOUT": "0"}
        script = "set -euo pipefail\n" + "\n".join(f"{key}={shlex.quote(value)}" for key, value in variables.items())
        script += f"\nchflags() {{ return {23 if abort else 0}; }}\nsync() {{ :; }}\nsleep() {{ :; }}\n" + section
        result = subprocess.run(["bash", "-c", script], env=environment, capture_output=True, text=True)
        assert result.returncode == (23 if abort else 0), result.stderr
        operations = [json.loads(line) for line in calls.read_text().splitlines()]
        attached = [args[args.index('-mountpoint') + 1] for args in operations if args[0] == 'attach']
        detached = [args[1] for args in operations if args[0] == 'detach']
        assert len(attached) == 1 and detached == attached, operations
        assert not Path(attached[0]).exists(), "Eigener Mountpoint blieb liegen"
        assert foreign.read_bytes() == b"unchanged"
    print("ReleaseMountHarness: OK")
