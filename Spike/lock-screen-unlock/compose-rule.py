#!/usr/bin/env python3
"""
Edits an authorization right's plist, on stdin, and writes the result to stdout.

This exists because the one thing install.sh must never do is write a literal
rule. This Mac already carries another vendor's authorization plugin inside
system.login.screensaver; overwriting that rule would silently break their
product. Every edit here is read-modify-write, and every shape it does not
recognise is a refusal rather than a guess.

    security authorizationdb read system.login.screensaver 2>/dev/null \
        | python3 compose-rule.py add de.faceunlock.screensaver \
        | security authorizationdb write system.login.screensaver

Subcommands:
    add <rule>              insert <rule> first, so the face branch is tried before
                            the password prompt
    remove <rule>           take <rule> out again, leaving every other entry alone
    kofn                    print the container's k-of-n, or "none"
    show                    print the rule graph in a readable form
"""

import plistlib
import sys

FALLBACK_LAST = "use-login-window-ui"


def fail(message):
    print(f"compose-rule: {message}", file=sys.stderr)
    sys.exit(1)


def load():
    data = sys.stdin.buffer.read()
    if not data.strip():
        fail("no plist on stdin")
    try:
        return plistlib.loads(data)
    except Exception as error:                       # noqa: BLE001
        fail(f"stdin is not a valid plist ({error})")


def container_rules(rule):
    """The sub-rule list of a container rule, or a refusal."""
    if rule.get("class") != "rule":
        fail(
            f"this right has class '{rule.get('class')}', not 'rule'. "
            "Composing it automatically is not safe; edit it by hand."
        )
    rules = rule.get("rule")
    if isinstance(rules, str):
        rules = [rules]
    if not isinstance(rules, list) or not rules:
        fail("this right has no sub-rule list to compose into")
    return rules


def emit(rule):
    sys.stdout.buffer.write(plistlib.dumps(rule, fmt=plistlib.FMT_XML))


def add(rule, name):
    rules = container_rules(rule)
    if name in rules:
        emit(rule)                                   # already composed; idempotent
        return

    existing_kofn = rule.get("k-of-n")
    # Setting k-of-n to 1 where it was absent and there was more than one
    # sub-rule would turn "all of these must pass" into "any one of them",
    # which is a weakening. Refuse rather than silently loosen the right.
    if existing_kofn is None and len(rules) > 1:
        fail(
            f"this right requires all {len(rules)} of its sub-rules and has no "
            "k-of-n. Adding a branch would weaken it; edit it by hand."
        )
    if existing_kofn is not None and existing_kofn != 1:
        fail(f"this right has k-of-n = {existing_kofn}; only 1 is supported")

    # First, so the face branch is tried before anything prompts. The password
    # branch stays last, which is what makes it the final word.
    rules = [name] + [entry for entry in rules if entry != name]
    if FALLBACK_LAST in rules:
        rules = [entry for entry in rules if entry != FALLBACK_LAST] + [FALLBACK_LAST]

    rule["rule"] = rules
    rule["k-of-n"] = 1
    emit(rule)


def remove(rule, name, kofn):
    rules = container_rules(rule)
    remaining = [entry for entry in rules if entry != name]
    if not remaining:
        fail(
            "removing that branch would leave the right with no sub-rules at "
            "all, which would make it ungrantable. Restore from the backup."
        )
    rule["rule"] = remaining
    # Put k-of-n back the way the install found it, so uninstalling is a true
    # inverse rather than an approximation.
    if kofn == "none":
        rule.pop("k-of-n", None)
    elif kofn is not None:
        rule["k-of-n"] = int(kofn)
    emit(rule)


def show(rule):
    rules = rule.get("rule")
    if isinstance(rules, str):
        rules = [rules]
    kofn = rule.get("k-of-n", "all")
    print(f"    class = {rule.get('class')}, k-of-n = {kofn}")
    for index, entry in enumerate(rules or []):
        branch = "`--" if index == len(rules) - 1 else "|--"
        note = "  <- password" if entry == FALLBACK_LAST else ""
        print(f"    {branch} {entry}{note}")


def main():
    if len(sys.argv) < 2:
        fail("usage: compose-rule.py add|remove|kofn|show [rule] [kofn]")
    command = sys.argv[1]
    rule = load()

    if command == "add":
        if len(sys.argv) < 3:
            fail("add needs a rule name")
        add(rule, sys.argv[2])
    elif command == "remove":
        if len(sys.argv) < 3:
            fail("remove needs a rule name")
        remove(rule, sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif command == "kofn":
        print(rule.get("k-of-n", "none"))
    elif command == "show":
        show(rule)
    else:
        fail(f"unknown subcommand '{command}'")


if __name__ == "__main__":
    main()
