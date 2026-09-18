#!/usr/bin/env bash
#
# Tests uninstall.sh without root and without touching this Mac.
#
#   ./test-uninstall.sh
#
# uninstall.sh is the most dangerous script in this directory, and it is the one
# that has to work on the day something has already gone wrong. So it gets a
# test that can be run before every change to it.
#
# The harness redirects every absolute path at a temporary root and stubs
# `security authorizationdb` and `launchctl`. The rule it works on is this Mac's
# *real* system.login.screensaver, read once, so the fixture is never a
# simplified idea of what the rule looks like.
#
set -uo pipefail
cd "$(dirname "$0")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/db" "$T/root/support"
PASSES=0
FAILURES=0

check() {
    if [ "$2" = "$3" ]; then
        echo "  ok    $1"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL  $1 (expected '$3', got '$2')"
        FAILURES=$((FAILURES + 1))
    fi
}

# ------------------------------------------------------------------ stubs
cat > "$T/bin/security" <<EOS
#!/bin/bash
DB="$T/db"
if [ "\$1" = "authorizationdb" ]; then
  case "\$2" in
    read)   [ -f "\$DB/\$3.plist" ] && cat "\$DB/\$3.plist" || exit 1 ;;
    write)  cat > "\$DB/\$3.plist" ;;
    remove) rm -f "\$DB/\$3.plist" ;;
  esac
  exit 0
fi
exit 1
EOS
cat > "$T/bin/launchctl" <<EOS
#!/bin/bash
M="$T/root/daemon-loaded"
case "\$1" in
  print)   [ -f "\$M" ] && exit 0 || exit 1 ;;
  bootout) rm -f "\$M"; exit 0 ;;
esac
exit 0
EOS
chmod +x "$T/bin/security" "$T/bin/launchctl"

cp compose-rule.py "$T/"
sed -e "s#/Library/Application Support/FaceUnlock#$T/root/support#g" \
    -e "s#/Library/Security/SecurityAgentPlugins#$T/root/plugins#g" \
    -e "s#/Library/PrivilegedHelperTools#$T/root/helpers#g" \
    -e "s#/Library/LaunchDaemons#$T/root/daemons#g" \
    -e 's#^\[ "\$(id -u)" = "0" \].*#true#' \
    uninstall.sh > "$T/uninstall.sh"
chmod +x "$T/uninstall.sh"
export PATH="$T/bin:$PATH"

# The real rule from this Mac, so the fixture is not a simplification.
ORIGINAL="$T/original.plist"
LIVE="$T/live.plist"
if ! /usr/bin/security authorizationdb read system.login.screensaver 2>/dev/null > "$LIVE"; then
    echo "Could not read system.login.screensaver to build the fixture." >&2
    exit 1
fi

# Normalise the fixture by stripping our own branch, if stage 1 happens to be
# installed on this Mac. Without this the test measures the machine's current
# state rather than the script: the "original" would already contain the branch
# the uninstall is supposed to remove, and restoring it exactly would be
# impossible by construction. The fixture must describe a Mac *before*
# installation, whatever this one looks like right now.
LIVE_KOFN="$(python3 compose-rule.py kofn < "$LIVE" 2>/dev/null || echo 1)"
if ! python3 compose-rule.py remove de.faceunlock.screensaver "$LIVE_KOFN" \
        < "$LIVE" > "$ORIGINAL" 2>/dev/null; then
    cp "$LIVE" "$ORIGINAL"
fi

simulate_install() {
    rm -rf "$T/root"
    mkdir -p "$T/root/support" "$T/root/plugins/FaceUnlock.bundle" \
             "$T/root/helpers" "$T/root/daemons"
    python3 compose-rule.py add de.faceunlock.screensaver < "$ORIGINAL" \
        > "$T/db/system.login.screensaver.plist"
    echo '<plist><dict/></plist>' > "$T/db/de.faceunlock.screensaver.plist"
    echo '<plist><dict/></plist>' > "$T/db/de.faceunlock.probe.plist"
    cp "$ORIGINAL" "$T/root/support/authdb-backup-20260101T000000Z.plist"
    touch "$T/root/helpers/de.faceunlock.daemon" \
          "$T/root/daemons/de.faceunlock.daemon.plist" \
          "$T/root/support/peers.plist" "$T/root/daemon-loaded"
}

break_the_rule() {
    python3 - "$T/db/system.login.screensaver.plist" <<'PY'
import plistlib, sys
plistlib.dump({"class": "evaluate-mechanisms",
               "mechanisms": ["de.faceunlock.screensaver", "builtin:authenticate"]},
              open(sys.argv[1], "wb"))
PY
}

same_as_original() {
    python3 - "$ORIGINAL" "$T/db/system.login.screensaver.plist" <<'PY'
import plistlib, sys
a = plistlib.load(open(sys.argv[1], "rb"))
b = plistlib.load(open(sys.argv[2], "rb"))
print("yes" if a == b else "no")
PY
}

branch_present() {
    grep -q "$1" "$T/db/system.login.screensaver.plist" && echo yes || echo no
}

echo "Testing uninstall.sh against a copy of this Mac's real screensaver rule."
echo

# 1 ---------------------------------------------------------------- happy path
simulate_install
"$T/uninstall.sh" >/dev/null 2>&1
check "a full install is removed cleanly"            "$?"                    "0"
check "the rule is restored exactly"                 "$(same_as_original)"   "yes"
check "the other vendor's branch survives"           "$(branch_present com.openai.sky)" "yes"
check "the password branch survives"                 "$(branch_present use-login-window-ui)" "yes"
check "our own right is gone"                        "$([ -f "$T/db/de.faceunlock.screensaver.plist" ] && echo yes || echo no)" "no"
check "the probe right is gone"                      "$([ -f "$T/db/de.faceunlock.probe.plist" ] && echo yes || echo no)" "no"
check "the mechanism bundle is gone"                 "$([ -e "$T/root/plugins/FaceUnlock.bundle" ] && echo yes || echo no)" "no"
check "the daemon binary is gone"                    "$([ -e "$T/root/helpers/de.faceunlock.daemon" ] && echo yes || echo no)" "no"
check "peer pinning is gone"                         "$([ -e "$T/root/support/peers.plist" ] && echo yes || echo no)" "no"
check "the backup is kept"                           "$(ls "$T/root/support"/authdb-backup-*.plist >/dev/null 2>&1 && echo yes || echo no)" "yes"

# 2 --------------------------------------------------------------- idempotency
"$T/uninstall.sh" >/dev/null 2>&1
check "running it again succeeds"                    "$?"                    "0"
check "and changes nothing"                          "$(same_as_original)"   "yes"

# 3 ----------------------------------------------- unrecognised shape + backup
simulate_install
break_the_rule
"$T/uninstall.sh" >/dev/null 2>&1
check "an unrecognised rule falls back to the backup" "$?"                   "0"
check "and the backup restores it exactly"           "$(same_as_original)"   "yes"

# 4 ------------------------------------------- unrecognised shape, no backup
simulate_install
break_the_rule
rm -f "$T/root/support"/authdb-backup-*.plist
cp "$T/db/system.login.screensaver.plist" "$T/before.plist"
"$T/uninstall.sh" >/dev/null 2>&1
check "with no backup it reports failure"            "$?"                    "1"
# The important one. A composer that refuses must not still result in a write:
# a half-written screensaver rule is the worst outcome this project can produce.
check "and leaves the rule untouched rather than truncated" \
    "$(cmp -s "$T/before.plist" "$T/db/system.login.screensaver.plist" && echo yes || echo no)" "yes"

# 5 ---------------------------------------------------------- nothing installed
rm -rf "$T/root"; mkdir -p "$T/root/support"
rm -f "$T/db/de.faceunlock.screensaver.plist" "$T/db/de.faceunlock.probe.plist"
cp "$ORIGINAL" "$T/db/system.login.screensaver.plist"
"$T/uninstall.sh" >/dev/null 2>&1
check "uninstalling a clean system succeeds"         "$?"                    "0"
check "and changes nothing"                          "$(same_as_original)"   "yes"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "$PASSES checks passed."
else
    echo "$PASSES passed, $FAILURES FAILED." >&2
    exit 1
fi
