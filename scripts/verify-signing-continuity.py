#!/usr/bin/env python3
"""Verify that a changed local build retains the same signing identity/DR."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

app = Path(sys.argv[1] if len(sys.argv) > 1 else 'dist/USBKey.app').resolve()
project = Path(__file__).resolve().parent.parent

def run(args):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if p.returncode:
        raise SystemExit(p.stderr.strip() or 'Verification failed')
    return p.stdout + p.stderr

def details(path):
    report = run(['/usr/bin/codesign', '-d', '-r-', '--verbose=3', path])
    requirement = re.search(r'^designated => (.+)$', report, re.M)
    code_hash = re.search(r'^CDHash=(.+)$', report, re.M)
    if not requirement or not code_hash:
        raise SystemExit('Missing code signing identity')
    return requirement.group(1), code_hash.group(1)

original_requirement, original_hash = details(app)
if 'certificate leaf =' not in original_requirement:
    raise SystemExit('This check expects the stable local certificate, not ad-hoc signing.')
with tempfile.TemporaryDirectory(prefix='USBKey-continuity-') as folder:
    future = Path(folder)/'USBKey.app'
    shutil.copytree(app, future)
    info = future/'Contents/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data['USBKeySigningContinuityProbe'] = os.urandom(16).hex()
    info.write_bytes(plistlib.dumps(data))
    run([sys.executable, project/'scripts/sign-app.py', future])
    run(['/usr/bin/codesign', '--verify', '--strict', future])
    new_requirement, new_hash = details(future)
    if new_requirement != original_requirement or new_hash == original_hash:
        raise SystemExit('Signing continuity failed')
print('Signing continuity verified: changed code hash, identical certificate-bound designated requirement.')
