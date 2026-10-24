#!/usr/bin/env python3
"""Create an isolated local development identity. Does not add a trusted root."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

root = Path.home() / 'Library/Application Support/USBKey Build Signing'
root.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(root, 0o700)
config = root / 'identity.json'

def run(args):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(p.stderr.strip() or 'Local signing operation failed')
    return p.stdout

if config.exists():
    print('Existing local identity retained:', root)
    raise SystemExit(0)

password_file = root / 'keychain-password'
keychain = root / 'signing.keychain-db'
if keychain.exists() or password_file.exists():
    raise SystemExit('Incomplete signing setup exists; refusing to overwrite the existing key.')
password = os.urandom(32).hex()
password_file.write_text(password)
os.chmod(password_file, 0o600)
old_search = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
with tempfile.TemporaryDirectory(prefix='USBKey-signing-') as directory:
    work = Path(directory)
    settings = work / 'openssl.cnf'
    settings.write_text('''[req]
prompt=no
distinguished_name=dn
x509_extensions=signing
[dn]
CN=USBKey Local Development
[signing]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
''')
    run(['/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650', '-config', settings, '-keyout', work/'key.pem', '-out', work/'certificate.pem'])
    run(['/usr/bin/openssl', 'x509', '-in', work/'certificate.pem', '-outform', 'DER', '-out', root/'certificate.der'])
    fingerprint = hashlib.sha1((root/'certificate.der').read_bytes()).hexdigest().upper()
    run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', work/'key.pem', '-in', work/'certificate.pem', '-out', work/'identity.p12', '-passout', 'file:' + str(password_file)])
    try:
        run(['/usr/bin/security', 'create-keychain', '-p', password, keychain])
        run(['/usr/bin/security', 'set-keychain-settings', '-lut', '300', keychain])
        run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain])
        run(['/usr/bin/security', 'import', work/'identity.p12', '-k', keychain, '-P', password, '-T', '/usr/bin/codesign'])
        run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, keychain])
    finally:
        run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *old_search])
    probe = work/'signing-probe'
    shutil.copyfile('/usr/bin/true', probe)
    os.chmod(probe, 0o700)
    requirement = '=designated => identifier "local.usbkey.signing-probe" and certificate leaf = H"' + fingerprint + '"'
    run(['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', keychain, '--identifier', 'local.usbkey.signing-probe', '--timestamp=none', '--requirements', requirement, probe])
    run(['/usr/bin/codesign', '--verify', '--strict', probe])
    config.write_text(json.dumps({'fingerprint': fingerprint, 'keychain': str(keychain)}, indent=2))
    os.chmod(config, 0o600)
print('Local signing identity verified:', root)
print('No certificate trust settings were changed.')
