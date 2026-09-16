#!/usr/bin/env python3
"""Flags blocking, `noasync`-annotated APIs called directly inside an async function.

Swift 6 marks a number of blocking Foundation and Dispatch APIs `@available(*, noasync)`
because calling them from a cooperative-pool thread can deadlock the concurrency
runtime. Calling one inside an `async func` is a compile error:

    Instance method 'lock' is unavailable from asynchronous contexts;
    Use async-safe scoped locking instead

The fix is to move the blocking region into a synchronous helper, or — when it can
block for a meaningful time — onto a dispatch queue behind a continuation.

This is a heuristic (brace-depth based, not a Swift parser), so treat a hit as
"look at this", not as a verdict.

Usage: Scripts/check-noasync-locks.py [root ...]
"""
import pathlib
import re
import sys

ASYNC_FUNC = re.compile(r'\bfunc\s+(\w+)[^{]*\basync\b')
BLOCKING = re.compile(
    r'\b\w*[Ll]ock\.(lock|unlock)\(\)'
    r'|\.waitUntilExit\(\)'
    r'|\bDispatchQueue\.\w+\.sync\b'
    r'|\bsemaphore\.wait\('
)


COMMENT = re.compile(r'//.*$')


def check(path: pathlib.Path) -> list[str]:
    findings = []
    depth = 0
    async_scopes = []
    for index, raw in enumerate(path.read_text().split('\n')):
        # Strip line comments so prose about a blocking API is not mistaken for a
        # call to one. (Doc comments routinely name the very API being avoided.)
        line = COMMENT.sub('', raw)
        stripped = line.strip()
        match = ASYNC_FUNC.search(stripped)
        if match and '{' in line:
            async_scopes.append((depth, index + 1, match.group(1)))
        if BLOCKING.search(line):
            for scope_depth, scope_line, name in async_scopes:
                if depth > scope_depth:
                    findings.append(
                        f'{path}:{index + 1}: blocking call inside '
                        f'async func {name}() declared at line {scope_line}'
                    )
                    break
        depth += line.count('{') - line.count('}')
        async_scopes = [s for s in async_scopes if s[0] < depth]
    return findings


def main() -> int:
    roots = sys.argv[1:] or ['FaceUnlock', 'FaceUnlockTests']
    findings = []
    for root in roots:
        for path in sorted(pathlib.Path(root).rglob('*.swift')):
            findings.extend(check(path))
    for finding in findings:
        print(finding)
    if findings:
        print(f'\n{len(findings)} blocking call(s) reachable from an async context.')
        return 1
    print('No noasync hazards found.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
