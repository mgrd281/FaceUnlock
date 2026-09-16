#!/usr/bin/env python3
"""Flags concurrent closures nested inside an unbound `[weak self]` capture.

A `[weak self]` capture is a mutable box — it can become nil at any moment — so a
nested closure that reads it while running concurrently is a data race. Swift 6
rejects it with:

    Reference to captured var 'self' in concurrently-executing code

The fix is always the same: bind it once, synchronously, before the inner closure.

    { [weak self] in
        guard let self else { return }      // <- bind here
        Task { await self.doSomething() }   // <- inner closure captures a `let`
    }

This is a heuristic (indentation- and brace-based, not a Swift parser), so treat a
hit as "look at this", not as a verdict.

Usage: Scripts/check-weak-self-captures.py [root ...]
"""
import pathlib
import re
import sys

CONCURRENT = re.compile(r'(Task\s*\{|\.async\s*\{)')
BINDS_SELF = re.compile(r'guard\s+let\s+(self|\w+\s*=\s*self)\b')


def check(path: pathlib.Path) -> list[str]:
    findings = []
    depth = 0
    weak_scopes = []
    for index, line in enumerate(path.read_text().split('\n')):
        stripped = line.strip()
        if '[weak self]' in line:
            weak_scopes.append({'depth': depth, 'line': index + 1, 'bound': False})
        if BINDS_SELF.search(stripped):
            for scope in weak_scopes:
                scope['bound'] = True
        if CONCURRENT.search(stripped):
            for scope in weak_scopes:
                if depth > scope['depth'] and not scope['bound']:
                    findings.append(
                        f'{path}:{index + 1}: concurrent closure reads the unbound '
                        f'[weak self] captured at line {scope["line"]}'
                    )
        depth += line.count('{') - line.count('}')
        weak_scopes = [scope for scope in weak_scopes if scope['depth'] < depth]
    return findings


def main() -> int:
    roots = sys.argv[1:] or ['FaceUnlock']
    findings = []
    for root in roots:
        for path in sorted(pathlib.Path(root).rglob('*.swift')):
            findings.extend(check(path))
    for finding in findings:
        print(finding)
    if findings:
        print(f'\n{len(findings)} site(s) need `guard let self` before the inner closure.')
        return 1
    print('No nested weak-self concurrency hazards found.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
