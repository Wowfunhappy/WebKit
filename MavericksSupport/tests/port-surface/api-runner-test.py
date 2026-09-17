#!/usr/bin/env python3
"""Exercise the real shell runner with isolated fake build products."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class APIRunnerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="api-runner-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "MavericksSupport/scripts"
        scripts.mkdir(parents=True)
        source = Path(__file__).resolve().parents[2] / "scripts"
        for name in ("run-api-tests.sh", "parse-api-test-list.awk", "run-api-test-with-timeout.py"):
            shutil.copyfile(source / name, scripts / name)
        python = self.root / "MavericksSupport/toolchain/build/python3/bin/python3"
        python.parent.mkdir(parents=True)
        python.symlink_to(sys.executable)
        self.runner = scripts / "run-api-tests.sh"
        (scripts / "make-build-binaries-runnable.sh").write_text("#!/bin/bash\nexit 0\n")
        self.binary = self.root / "WebKitBuild/Release/bin/TestFixture"
        self.binary.parent.mkdir(parents=True)
        expectations = self.root / "MavericksSupport/tests/port-surface/api-tests.txt"
        expectations.parent.mkdir(parents=True)
        expectations.write_text("run TestFixture\n")
        self.commands = self.root / "commands"
        self.commands.mkdir()
        # Process cleanup belongs to the fixture, not to other host test runs.
        cleanup = self.commands / "pkill"
        cleanup.write_text("#!/bin/bash\nexit 0\n")
        cleanup.chmod(0o755)

    def run_fixture(self, script, *arguments):
        self.binary.write_text("#!/bin/bash\n" + script)
        self.binary.chmod(0o755)
        environment = os.environ.copy()
        environment.update(PATH=str(self.commands) + os.pathsep + environment["PATH"],
                           TZ="UTC", WK_API_TEST_TIMEOUT="2", LC_ALL="C")
        return subprocess.run(["/bin/bash", str(self.runner), "--port-surface", *arguments],
                              env=environment, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, universal_newlines=True, timeout=20)

    def test_parameterized_tests_and_timezone(self):
        result = self.run_fixture('''
if [ "$1" = --gtest_list_tests ]; then
    printf '%s\\n' 'Plain.' '  First' 'Typed/0.  # TypeParam = int' '  Convert' \\
        'Values/Suite.' '  Works/0  # GetParam() = 12' '  DISABLED_Works/1'
    exit 0
fi
[ "$TZ" = US/Pacific ] || exit 9
printf '**PASS** %s\\n' "${1#--gtest_filter=}"
''')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('Ran 3 tests (0 skipped): 3 as expected, 0 unexpected', result.stdout)
        self.assertIn('TestFixture Typed/0.Convert', result.stdout)
        self.assertIn('TestFixture Values/Suite.Works/0', result.stdout)

    def test_partial_enumeration_failure_is_fatal(self):
        result = self.run_fixture('''
printf '%s\\n' 'Plain.' '  First'
echo 'fixture discovery failure' >&2
exit 12
''')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('failed to enumerate tests', result.stdout)
        self.assertIn('fixture discovery failure', result.stdout)
        self.assertNotIn('Ran 1 tests', result.stdout)

    def test_pass_marker_must_name_exact_test(self):
        result = self.run_fixture('''
if [ "$1" = --gtest_list_tests ]; then
    printf '%s\\n' 'Plain.' '  First'
else
    echo '**PASS** Plain.FirstExtra'
fi
''')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('0 as expected, 1 unexpected', result.stdout)

    def test_nonzero_exit_overrides_pass_marker(self):
        result = self.run_fixture('''
if [ "$1" = --gtest_list_tests ]; then
    printf '%s\\n' 'Plain.' '  First'
else
    echo '**PASS** Plain.First'
    exit 19
fi
''')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('0 as expected, 1 unexpected', result.stdout)

    def test_timeout_is_failure(self):
        result = self.run_fixture('''
if [ "$1" = --gtest_list_tests ]; then
    printf '%s\\n' 'Plain.' '  First'
else
    exec /bin/sleep 30
fi
''')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('timed out after 2s', result.stdout)
        self.assertIn('0 as expected, 1 unexpected', result.stdout)


if __name__ == "__main__":
    unittest.main()
