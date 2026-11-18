#!/usr/bin/env python3
"""Fails unless an xcodebuild result bundle shows the gating tests actually ran.

`xcodebuild -only-testing:<Target>/<Class>` exits 0 when a selector matches nothing (a renamed or
deleted class), so a green exit code alone cannot show that the privacy tests ran. This reads the
result bundle and requires, for every class named on the command line, at least one executed test
case of that class, and no failed, skipped or expected-failure test among the run's totals.

Usage: assert_tests_ran.py <result.xcresult> <ClassName> [<ClassName> ...]
Exit:  0 every class ran and nothing failed or was skipped · 1 a class ran no test, a test failed or
       was skipped, or the run executed none · 2 the result bundle could not be read.
"""
import json
import subprocess
import sys


def xcresult(args):
    try:
        out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", *args, "--compact"],
                             capture_output=True, text=True, check=True).stdout
        return json.loads(out)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        detail = getattr(exc, "stderr", "") or exc
        print(f"COULD NOT VERIFY: xcresulttool failed: {detail}")
        sys.exit(2)


def test_cases(node, inside=()):
    """Yields (enclosing node names, test case node) for every Test Case under `node`."""
    here = inside + (node.get("name", ""),)
    if node.get("nodeType") == "Test Case":
        yield here, node
    for child in node.get("children") or []:
        yield from test_cases(child, here)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    path, classes = argv[1], argv[2:]
    summary = xcresult(["summary", "--path", path])
    total = int(summary.get("totalTestCount", 0))
    failed = int(summary.get("failedTests", 0))
    skipped = int(summary.get("skippedTests", 0))
    expected_failures = int(summary.get("expectedFailures", 0))
    problems = []
    if total == 0:
        problems.append("the run executed 0 tests")
    if failed or skipped or expected_failures:
        problems.append(f"failed={failed} skipped={skipped} expectedFailures={expected_failures}")

    ran = {name: 0 for name in classes}
    for root in xcresult(["tests", "--path", path]).get("testNodes") or []:
        for enclosing, case in test_cases(root):
            if case.get("result") in ("Passed", "Failed"):
                for name in classes:
                    if name in enclosing:
                        ran[name] += 1
    for name, count in ran.items():
        if count == 0:
            problems.append(f"{name} ran no test")

    counts = ", ".join(f"{name}: {count}" for name, count in ran.items())
    if problems:
        print(f"FAIL: {'; '.join(problems)} (total {total}; {counts})")
        return 1
    print(f"PASS: {total} test(s) ran, none failed or skipped ({counts})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
