#!/usr/bin/env python3
"""Run one API test with a wall-clock deadline and inherited output streams."""

import argparse
import math
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    if not args.command:
        parser.error("a test command is required")
    try:
        result = subprocess.run(args.command, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        print("timed out after {:g}s".format(args.timeout), flush=True)
        return 124
    except OSError as error:
        print("could not launch API test: {}".format(error), flush=True)
        return 127
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
