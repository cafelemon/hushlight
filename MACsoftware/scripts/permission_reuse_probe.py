#!/usr/bin/env python3
"""Build an isolated, locally signed Notes TCC probe. Never reset TCC or change trust."""
import argparse
from datetime import datetime, timezone
import os
import signal
import time
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
CONFIG = Path.home() / 'Library/Application Support/Hushlight/Development/signing.json'
APP = Path.home() / 'Applications/Agent Workbench Permission Probe.app'
EVIDENCE = PROJECT / 'evidence/2026-10-23-permission-reuse'
STATE = Path.home() / 'Library/Application Support/Hushlight/Development/permission-probe.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-version', choices=['1', '2'])
    parser.add_argument('--check-results', action='store_true', help='Verify persisted version-1 grant and version-2 no-prompt reuse; never grants permission')
    parser.add_argument('--open', action='store_true', help='Open probe; authorization is still explicit button-only')
    args = parser.parse_args()
    if args.check_results:
        before = json.loads((EVIDENCE / 'permission-before-rebuild.json').read_text())
        first = json.loads((EVIDENCE / 'probe-build-1.json').read_text())
        second = json.loads((EVIDENCE / 'probe-build-2.json').read_text())
        after = json.loads(STATE.read_text())
        verify_installed(APP, second)
        validate_reuse(before, first, second, after)
        (EVIDENCE / 'permission-after-rebuild.json').write_text(json.dumps(after, indent=2) + '\n')
        print('PASS: Notes automation remained granted after real executable rebuild, without another request. Other permissions untested.')
        return
    if not args.build_version:
        parser.error('--build-version or --check-results required')
    if args.build_version == '2':
        before = json.loads(STATE.read_text())
        if before.get('build') != '1' or before.get('notesAutomation') != 'granted':
            parser.error('Version 1 must be granted by the user first. No rebuild or permission request performed.')
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        (EVIDENCE / 'permission-before-rebuild.json').write_text(json.dumps(before, indent=2) + '\n')
        stop_probe()
    identity = json.loads(CONFIG.read_text())
    if identity.get('probe') != 'signature_identity_pass':
        parser.error('Run setup_local_signing.py first. Main App is never migrated here.')
    APP.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='workbench-tcc-probe-') as directory:
        root = Path(directory)
        app = root / APP.name
        (app / 'Contents/MacOS').mkdir(parents=True)
        source = (PROJECT / 'scripts/fixtures/PermissionReuseProbe.swift').read_text()
        # Ensure a real executable difference across rebuilds, not just a plist change.
        source += '\nprivate let probeBuildIdentity = "build-' + args.build_version + '"\n'
        source_path = root / 'PermissionReuseProbe.swift'
        source_path.write_text(source)
        executable = app / 'Contents/MacOS/PermissionReuseProbe'
        subprocess.run(['swiftc', '-parse-as-library', str(source_path), '-o', str(executable)], check=True)
        info = {'CFBundleIdentifier': 'com.hushlight.workbench.permission-probe', 'CFBundleExecutable': 'PermissionReuseProbe',
                'CFBundleName': '工作台权限复用测试', 'CFBundleDisplayName': '工作台权限复用测试',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': args.build_version,
                'CFBundleShortVersionString': '0.0.' + args.build_version,
                'NSAppleEventsUsageDescription': '仅测试备忘录自动化授权在签名重建后是否保留，不读取笔记内容。',
                'LSMinimumSystemVersion': '13.0'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--timestamp=none', '--sign', identity['identity_sha1'], str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
        signature = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, text=True, check=True)
        requirement = next(line for line in (signature.stdout + signature.stderr).splitlines() if line.startswith('designated =>'))
        evidence = EVIDENCE
        evidence.mkdir(parents=True, exist_ok=True)
        build_evidence = {
            'build': args.build_version, 'builtAt': datetime.now(timezone.utc).isoformat(), 'bundleID': info['CFBundleIdentifier'],
            'designatedRequirement': requirement, 'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
            'tccAcceptance': 'not_verified_by_build'}
        if args.build_version == '2':
            baseline = json.loads((evidence / 'probe-build-1.json').read_text())
            if baseline['designatedRequirement'] != requirement:
                raise RuntimeError('Designated requirement changed. Probe not installed.')
            if baseline['executableSHA256'] == hashlib.sha256(executable.read_bytes()).hexdigest():
                raise RuntimeError('Executable did not change. Probe not installed.')
        staging = APP.with_name('.Agent Workbench Permission Probe.installing.app')
        if staging.exists():
            shutil.rmtree(staging)
        shutil.copytree(app, staging)
        backup = APP.with_name('.Agent Workbench Permission Probe.previous.app')
        if backup.exists():
            shutil.rmtree(backup)
        if APP.exists():
            APP.rename(backup)
        staging.rename(APP)
        verify_installed(APP, build_evidence)
        (evidence / ('probe-build-' + args.build_version + '.json')).write_text(json.dumps(build_evidence, indent=2) + '\n')
    print(APP)
    if args.open:
        subprocess.run(['/usr/bin/open', '-a', str(APP)], check=True)


def verify_installed(app, evidence):
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    signature = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, text=True, check=True)
    requirement = next(line for line in (signature.stdout + signature.stderr).splitlines() if line.startswith('designated =>'))
    digest = hashlib.sha256((app / 'Contents/MacOS/PermissionReuseProbe').read_bytes()).hexdigest()
    if (info.get('CFBundleIdentifier') != evidence['bundleID'] or
            info.get('CFBundleVersion') != evidence['build'] or
            requirement != evidence['designatedRequirement'] or digest != evidence['executableSHA256']):
        raise RuntimeError('Installed application does not match build evidence')


def validate_reuse(before, first, second, after):
    if before.get('build') != '1' or before.get('notesAutomation') != 'granted':
        raise RuntimeError('No real version-1 grant evidence')
    if first.get('bundleID') != second.get('bundleID') or first.get('designatedRequirement') != second.get('designatedRequirement'):
        raise RuntimeError('Application identity changed')
    if not first.get('executableSHA256') or first.get('executableSHA256') == second.get('executableSHA256'):
        raise RuntimeError('No executable rebuild evidence')
    if after.get('build') != '2' or after.get('compiledBuild') != 'build-2' or after.get('notesAutomation') != 'granted' or after.get('requestedByButton') is not False:
        raise RuntimeError('Version 2 did not recover granted state without asking')
    checked = datetime.fromisoformat(after['checkedAt'].replace('Z', '+00:00'))
    built = datetime.fromisoformat(second['builtAt'].replace('Z', '+00:00'))
    if checked.timestamp() + 1 < built.timestamp():
        raise RuntimeError('Result predates the rebuild')


def stop_probe():
    # Terminate only our exact executable, so LaunchServices cannot reuse a stale v1 process.
    expected = str(APP / 'Contents/MacOS/PermissionReuseProbe')
    found = subprocess.run(['/usr/bin/pgrep', '-f', expected], capture_output=True, text=True)
    for value in found.stdout.splitlines():
        pid = int(value)
        command = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
        if command != expected:
            continue
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError('Probe still running. Rebuild not installed.')


if __name__ == '__main__':
    main()
