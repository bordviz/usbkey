#!/usr/bin/env python3
"""Sign USBKey with a stable identity; never silently fall back to ad-hoc signing."""
import json
import os
from pathlib import Path
import subprocess
import re
import sys

app = Path(sys.argv[1]).resolve()
identifier = sys.argv[2] if len(sys.argv) > 2 else "local.usbkey.app"
if not re.fullmatch(r"[A-Za-z0-9.-]+", identifier):
    raise SystemExit("Invalid signing identifier")
identity = os.environ.get('APP_SIGN_IDENTITY')
root = Path.home() / 'Library/Application Support/USBKey Build Signing'

def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or 'Signing failed')
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)

if identity and identity != '-':
    run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', identity, '--identifier', identifier, app])
elif (root/'identity.json').exists():
    config = json.loads((root/'identity.json').read_text())
    fingerprint = config['fingerprint']
    if len(fingerprint) != 40 or any(c not in '0123456789ABCDEF' for c in fingerprint):
        raise SystemExit('Invalid local signing fingerprint')
    keychain = config['keychain']
    run(['/usr/bin/security', 'unlock-keychain', '-p', (root/'keychain-password').read_text(), keychain])
    requirement = '=designated => identifier "' + identifier + '" and certificate leaf = H"' + fingerprint + '"'
    run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', fingerprint, '--keychain', keychain, '--timestamp=none', '--identifier', identifier, '--requirements', requirement, app])
elif os.environ.get('ALLOW_ADHOC_SIGNING') == '1':
    print('Warning: ad-hoc development build; TCC permission will not survive binary updates.', file=sys.stderr)
    run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', '-', app])
else:
    raise SystemExit('Stable signing identity required. Run: python3 scripts/setup-local-signing.py, or set APP_SIGN_IDENTITY.')
run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
