#!/usr/bin/env python3
import hashlib
import plistlib
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
import unittest
from permission_reuse_probe import validate_reuse, verify_installed

class PermissionReuseEvidenceTests(unittest.TestCase):
    def fixture(self):
        return ({'build': '1', 'notesAutomation': 'granted'},
                {'bundleID': 'probe', 'designatedRequirement': 'same', 'executableSHA256': 'a'},
                {'bundleID': 'probe', 'designatedRequirement': 'same', 'executableSHA256': 'b', 'builtAt': '2026-10-23T10:00:00+00:00'},
                {'build': '2', 'compiledBuild': 'build-2', 'notesAutomation': 'granted', 'requestedByButton': False, 'checkedAt': '2026-10-23T10:00:01Z'})

    def test_rebuilt_executable_retains_permission_without_reasking(self):
        validate_reuse(*self.fixture())

    def test_reasking_old_process_or_stale_results_cannot_pass(self):
        for changes in [{'requestedByButton': True}, {'build': '1'}, {'checkedAt': '2026-10-22T10:00:00Z'}, {'notesAutomation': 'needs_consent'}]:
            values = list(self.fixture()); values[3] = values[3] | changes
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                validate_reuse(*values)

    def test_identity_or_no_binary_change_cannot_pass(self):
        for changes in [{'bundleID': 'different'}, {'designatedRequirement': 'different'}, {'executableSHA256': 'a'}]:
            values = list(self.fixture()); values[2] = values[2] | changes
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                validate_reuse(*values)

class InstalledProbeTests(unittest.TestCase):
    def test_installed_version_signature_and_binary_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/PermissionReuseProbe').write_bytes(b'new executable')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'probe', 'CFBundleVersion': '2'}))
            expected = {'bundleID': 'probe', 'build': '2', 'designatedRequirement': 'designated => same',
                        'executableSHA256': hashlib.sha256(b'new executable').hexdigest()}
            result = subprocess.CompletedProcess([], 0, stdout='', stderr='designated => same')
            with patch('permission_reuse_probe.subprocess.run', return_value=result):
                verify_installed(app, expected)
                for changes in [{'build': '1'}, {'bundleID': 'wrong'}, {'executableSHA256': 'old'}, {'designatedRequirement': 'wrong'}]:
                    with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                        verify_installed(app, expected | changes)
            with patch('permission_reuse_probe.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'codesign')):
                with self.assertRaises(subprocess.CalledProcessError):
                    verify_installed(app, expected)


if __name__ == '__main__':
    unittest.main()
