#!/usr/bin/env python3
"""Flags SwiftUI containers with more than ten direct children.

`ViewBuilder` supports at most ten child views; going over produces a compiler
error that can be slow to diagnose. This is a heuristic (it counts statements by
indentation, not by parsing Swift), so treat a hit as "look at this", not as a
verdict.

Usage: Scripts/check-viewbuilder-limits.py [root ...]
"""
import pathlib
import re
import sys

CONTAINERS = re.compile(
    r'\b(VStack|HStack|ZStack|Group|Form|List|TabView|Section|GridRow|Grid)\b[^{]*\{\s*$'
)
LIMIT = 10
NOT_A_CHILD = ('.', 'let ', 'var ', '}', ')', ']', '@', '//')


def check(path: pathlib.Path) -> list[str]:
    findings = []
    lines = path.read_text().split('\n')
    for index, line in enumerate(lines):
        if not CONTAINERS.search(line):
            continue
        base = len(line) - len(line.lstrip())
        depth = 0
        children = 0
        for candidate in lines[index + 1:]:
            stripped = candidate.strip()
            indent = len(candidate) - len(candidate.lstrip())
            if depth == 0 and stripped.startswith('}') and indent <= base:
                break
            if depth == 0 and indent == base + 4 and stripped and not stripped.startswith(NOT_A_CHILD):
                children += 1
            depth += candidate.count('{') - candidate.count('}')
            if depth < 0:
                break
        if children > LIMIT:
            findings.append(f'{path}:{index + 1}: ~{children} children — {line.strip()[:70]}')
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
        print(f'\n{len(findings)} container(s) exceed the {LIMIT}-child ViewBuilder limit.')
        return 1
    print('No ViewBuilder child-count violations found.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
