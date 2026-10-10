#!/usr/bin/env python3
# Read test names (Binary.Suite.Test) on stdin and print each with "Pass" (run it; it must pass) or "Skip". The expectations are upstream's
# TestExpectations/apitests followed by TestExpectations/platform/mac-mavericks/apitests, read with
# upstream's webkitexpectationspy under this port's configuration.
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'Tools', 'Scripts', 'libraries', 'webkitexpectationspy'))

from webkitexpectationspy import ExpectationsManager, ResultStatus  # noqa: E402
from webkitexpectationspy.suites.api_tests import APITestSuite  # noqa: E402

GENERIC_EXPECTATIONS = 'TestExpectations/apitests'
PORT_EXPECTATIONS = 'TestExpectations/platform/mac-mavericks/apitests'
CONFIGURATION = {'mac', 'release', 'x86_64'}


class PortAPITestSuite(APITestSuite):
    # APITestSuite validates and matches trailing-`*` patterns but leaves is_wildcard_pattern at the base
    # class's False, so the model files them as exact names that never match.
    def is_wildcard_pattern(self, pattern):
        return pattern.endswith('*')


manager = ExpectationsManager(suite=PortAPITestSuite())
for relative in (GENERIC_EXPECTATIONS, PORT_EXPECTATIONS):
    path = os.path.join(ROOT, relative)
    with open(path) as file:
        warnings = manager.load_content(path, file.read())
    if relative == PORT_EXPECTATIONS:
        for warning in warnings:
            print(warning, file=sys.stderr)

for line in sys.stdin:
    test = line.strip()
    if not test:
        continue
    expectation = manager.get_expectation(test, current_config=CONFIGURATION, current_version='mavericks', version_order=[])
    if expectation is None:
        print(test + '\tPass')
        continue
    # Only a test expected to pass runs: an expected failure, crash or timeout, and a flaky expectation
    # (Pass together with any of those), is skipped, as run-layout-tests.sh's --skip-failing-tests does.
    if expectation.skip or expectation.expected != ResultStatus.PASS:
        print(test + '\tSkip')
    else:
        print(test + '\tPass')
