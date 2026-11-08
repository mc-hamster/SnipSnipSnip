"""The disposable audit must never dispatch into a shipping app."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / 'validate-automation-samples.py'
spec = importlib.util.spec_from_file_location('automation_samples', MODULE_PATH)
automation_samples = importlib.util.module_from_spec(spec)
spec.loader.exec_module(automation_samples)


class AutomationNamespaceTests(unittest.TestCase):
    def assert_refused_before_dispatch(self, apps, cli, expected_message):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'audit-output'
            discovery = subprocess.CompletedProcess([], 0, json.dumps(apps), '')
            errors = io.StringIO()
            with patch.object(automation_samples, 'run', return_value=discovery) as run, \
                 patch('sys.argv', ['validator', '--cli', cli, '--output', str(output)]), \
                 contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as raised:
                automation_samples.main()
            self.assertEqual(raised.exception.code, 2)
            self.assertIn(expected_message, errors.getvalue())
            self.assertEqual(run.call_count, 1, 'Refuse before AppleScript, CLI, clipboard, or file dispatch.')
            self.assertIn('com.oontz.SnipSnipSnip.Dev', run.call_args.args[0][-1])
            self.assertFalse(output.exists())

    def test_shipping_cli_cannot_be_used_with_a_dev_audit_fixture(self):
        self.assert_refused_before_dispatch(
            [{'pid': 123, 'path': '/tmp/Dev/SnipSnipSnip.app'}],
            '/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl',
            'CLI must belong to the running disposable Dev app')

    def test_no_dev_process_cannot_fall_back_to_shipping(self):
        self.assert_refused_before_dispatch([], '/tmp/cli', 'Exactly one isolated audit app')

    def test_ambiguous_dev_processes_are_rejected(self):
        self.assert_refused_before_dispatch(
            [{'pid': 123, 'path': '/tmp/One.app'}, {'pid': 456, 'path': '/tmp/Two.app'}],
            '/tmp/cli', 'Exactly one isolated audit app')


if __name__ == '__main__':
    unittest.main()
