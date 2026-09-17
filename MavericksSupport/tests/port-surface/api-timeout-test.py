#!/usr/bin/env python3
"""Check API test process completion, output, and deadline handling."""

from pathlib import Path
import subprocess
import sys
import unittest


class APITimeoutTest(unittest.TestCase):
    helper = Path(__file__).resolve().parents[2] / "scripts/run-api-test-with-timeout.py"

    def run_command(self, script, timeout="5"):
        return subprocess.run([sys.executable, str(self.helper), "--timeout", timeout,
                               sys.executable, "-c", script],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              universal_newlines=True, timeout=10)

    def test_success_and_output(self):
        result = self.run_command("print('**PASS** Fixture.Success')")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("**PASS** Fixture.Success", result.stdout)

    def test_nonzero_exit(self):
        result = self.run_command("raise SystemExit(19)")
        self.assertEqual(result.returncode, 19, result.stdout)

    def test_signal_exit(self):
        result = self.run_command("import os, signal; os.kill(os.getpid(), signal.SIGTERM)")
        self.assertEqual(result.returncode, 143, result.stdout)

    def test_timeout(self):
        result = self.run_command("import time; time.sleep(30)", "0.1")
        self.assertEqual(result.returncode, 124, result.stdout)
        self.assertIn("timed out after 0.1s", result.stdout)

    def test_invalid_deadline(self):
        for timeout in ("0", "-1", "nan", "inf"):
            result = self.run_command("print('must not run')", timeout)
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertNotIn("must not run", result.stdout)


if __name__ == "__main__":
    unittest.main()
