#!/usr/bin/env python3
"""Create a local development identity in the login keychain; never alter trust settings.

A separate probe is rebuilt twice. Only the public identity fingerprint is saved.
Does not migrate the App or claim TCC permission acceptance.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

NAME = 'Agent Workbench Local Development'
ROOT = Path.home() / 'Library/Application Support/Hushlight/Development'
CONFIG = ROOT / 'signing.json'

def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout

def main():
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(ROOT, 0o700)
    with tempfile.TemporaryDirectory(prefix='workbench-signing-') as temporary:
        task = Path(temporary)
        os.chmod(task, 0o700)
        if CONFIG.exists():
            fingerprint = json.loads(CONFIG.read_text())['identity_sha1']
        else:
            # Temporary private material is confined to a 0700 directory and removed
            # after import; no key is stored in the repository or the public config.
            conf = task / 'certificate.cnf'
            conf.write_text('[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=' + NAME + '\n[extensions]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
            run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-x509', '-days', '3650', '-config', str(conf), '-keyout', str(task / 'key.pem'), '-out', str(task / 'cert.pem')])
            os.chmod(task / 'key.pem', 0o600)
            fingerprint = hashlib.sha1(run(['openssl', 'x509', '-in', str(task / 'cert.pem'), '-outform', 'DER'])).hexdigest().upper()
            # Import as a signing identity. No add-trusted-cert or TCC reset.
            password = os.urandom(24).hex()
            environment = dict(os.environ, WORKBENCH_P12_PASSWORD=password)
            run(['openssl', 'pkcs12', '-export', '-legacy', '-inkey', str(task / 'key.pem'), '-in', str(task / 'cert.pem'), '-name', NAME, '-passout', 'env:WORKBENCH_P12_PASSWORD', '-out', str(task / 'identity.p12')], env=environment)
            keychain = run(['security', 'default-keychain', '-d', 'user'], text=True).strip().strip('"')
            run(['security', 'import', str(task / 'identity.p12'), '-k', keychain, '-P', password, '-T', '/usr/bin/codesign'])
            CONFIG.write_text(json.dumps({'identity_sha1': fingerprint, 'name': NAME, 'probe': 'not_run'}, indent=2) + '\n')
            os.chmod(CONFIG, 0o600)
        app = task / 'WorkbenchSigningProbe.app'
        binary = app / 'Contents/MacOS/probe'
        binary.parent.mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.hushlight.workbench.signing-probe', 'CFBundleExecutable': 'probe', 'CFBundlePackageType': 'APPL'}))
        requirements = []
        for version in [1, 2]:
            source = task / 'probe.c'
            source.write_text('int main(void) { return ' + str(version) + '; }\n')
            run(['clang', str(source), '-o', str(binary)])
            run(['codesign', '--force', '--timestamp=none', '--sign', fingerprint, str(app)])
            run(['codesign', '--verify', '--strict', str(app)])
            result = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, check=True, text=True)
            requirements.append(next(line for line in (result.stdout + result.stderr).splitlines() if line.startswith('designated =>')))
        if requirements[0] != requirements[1]:
            raise RuntimeError('Designated requirement changed across rebuilds')
        CONFIG.write_text(json.dumps({'identity_sha1': fingerprint, 'name': NAME, 'probe': 'signature_identity_pass', 'tcc_acceptance': 'untested'}, indent=2) + '\n')
        os.chmod(CONFIG, 0o600)
        print('PASS: rebuilt probe signatures have the same designated requirement. TCC reuse untested. Main App not migrated.')

if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Avoid dumping argv (P12 import contains a temporary password).
        print('FAIL: local signing setup/probe failed at executable: ' + Path(error.cmd[0]).name)
        raise SystemExit(1)
