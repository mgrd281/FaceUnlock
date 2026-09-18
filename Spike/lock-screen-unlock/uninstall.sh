#!/usr/bin/env bash
#
# Removes everything install.sh put in place.
#
#   sudo ./uninstall.sh
#
# Three properties this script is written to have, in order of importance:
#
#   1. It is surgical. It removes *only* the FaceUnlock branch from
#      system.login.screensaver and leaves every other sub-rule exactly as it
#      found it. Another vendor's authorization plugin already shares that rule
#      on this Mac.
#   2. It is idempotent. Running it twice, or running it when nothing is
#      installed, or running it after the app has already been deleted, is fine.
#   3. It never stops at the first failure. Every step is attempted even if an
#      earlier one failed, because the situation in which someone runs this is
#      usually one where something is already wrong.
#
# It deliberately does NOT delete the backups in
# /Library/Application Support/FaceUnlock/.
#
set -uo pipefail
cd "$(dirname "$0")"

SUPPORT_DIR="/Library/Application Support/FaceUnlock"
PLUGIN_DEST="/Library/Security/SecurityAgentPlugins/FaceUnlock.bundle"
DAEMON_DEST="/Library/PrivilegedHelperTools/de.faceunlock.daemon"
DAEMON_PLIST="/Library/LaunchDaemons/de.faceunlock.daemon.plist"
DAEMON_LABEL="de.faceunlock.daemon"
PROBE_RIGHT="de.faceunlock.probe"
FACE_RULE="de.faceunlock.screensaver"
REAL_RIGHT="system.login.screensaver"

[ "$(id -u)" = "0" ] || { echo "This must run as root: sudo ./uninstall.sh" >&2; exit 1; }

PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); echo "    ! $1" >&2; }

# ------------------------------------------- 1. get out of the unlock path first
# Before anything else, because this is the only step that affects whether the
# Mac can be unlocked.
echo "==> Removing the face branch from $REAL_RIGHT"
CURRENT="$(security authorizationdb read "$REAL_RIGHT" 2>/dev/null)"
if [ -z "$CURRENT" ]; then
    note_problem "could not read $REAL_RIGHT"
elif ! printf '%s' "$CURRENT" | grep -q "$FACE_RULE"; then
    echo "    not present; nothing to do"
else
    # Put k-of-n back the way the install found it, taken from the newest backup.
    NEWEST_BACKUP="$(ls -1t "$SUPPORT_DIR"/authdb-backup-*.plist 2>/dev/null | head -1)"
    ORIGINAL_KOFN="1"
    if [ -n "$NEWEST_BACKUP" ]; then
        ORIGINAL_KOFN="$(python3 compose-rule.py kofn < "$NEWEST_BACKUP" 2>/dev/null || echo 1)"
    fi

    # Staged through a file and validated before it is written. Piping the
    # composer straight into `authorizationdb write` would run the write even
    # when the composer produced nothing, leaving the outcome of the most
    # destructive operation here resting on how `security` happens to treat
    # empty stdin. It does not need to rest on anything.
    NEW_RULE="$(mktemp)"
    if printf '%s' "$CURRENT" \
        | python3 compose-rule.py remove "$FACE_RULE" "$ORIGINAL_KOFN" > "$NEW_RULE" 2>/dev/null \
        && [ -s "$NEW_RULE" ] \
        && plutil -lint "$NEW_RULE" >/dev/null 2>&1 \
        && security authorizationdb write "$REAL_RIGHT" < "$NEW_RULE" >/dev/null 2>&1
    then
        rm -f "$NEW_RULE"
        echo "    removed (k-of-n restored to $ORIGINAL_KOFN)"
    else
        # The surgical path failed, which means the rule is not in a shape this
        # script recognises. Fall back to the backup rather than guessing.
        rm -f "$NEW_RULE"
        echo "    surgical removal failed; restoring from backup"
        if [ -n "$NEWEST_BACKUP" ] \
            && security authorizationdb write "$REAL_RIGHT" < "$NEWEST_BACKUP" >/dev/null 2>&1
        then
            echo "    restored $NEWEST_BACKUP"
        else
            note_problem "could not restore $REAL_RIGHT — see RECOVERY in DESIGN.md §9"
        fi
    fi
fi

# --------------------------------------------------------- 2. the custom rights
echo "==> Removing the custom rights"
for right in "$FACE_RULE" "$PROBE_RIGHT"; do
    if security authorizationdb read "$right" >/dev/null 2>&1; then
        if security authorizationdb remove "$right" >/dev/null 2>&1; then
            echo "    removed $right"
        else
            note_problem "could not remove $right"
        fi
    fi
done

# -------------------------------------------------------------- 3. the daemon
echo "==> Stopping the broker"
if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 \
        && echo "    stopped" || note_problem "could not stop $DAEMON_LABEL"
else
    echo "    not running"
fi
for path in "$DAEMON_PLIST" "$DAEMON_DEST"; do
    if [ -e "$path" ]; then
        rm -f "$path" && echo "    removed $path" || note_problem "could not remove $path"
    fi
done

# ------------------------------------------------------------ 4. the mechanism
echo "==> Removing the mechanism"
if [ -e "$PLUGIN_DEST" ]; then
    rm -rf "$PLUGIN_DEST" && echo "    removed $PLUGIN_DEST" \
        || note_problem "could not remove $PLUGIN_DEST"
else
    echo "    not installed"
fi

# ------------------------------------------------------- 5. the peer pinning
if [ -e "$SUPPORT_DIR/peers.plist" ]; then
    rm -f "$SUPPORT_DIR/peers.plist" && echo "==> Removed peer requirements"
fi

echo
echo "Current state of $REAL_RIGHT:"
security authorizationdb read "$REAL_RIGHT" 2>/dev/null | python3 compose-rule.py show \
    || echo "    (could not be read)"

echo
if [ "$PROBLEMS" -eq 0 ]; then
    echo "Uninstalled. Backups kept in $SUPPORT_DIR."
else
    echo "Uninstalled with $PROBLEMS problem(s) — see the lines marked ! above." >&2
    echo "Backups are in $SUPPORT_DIR. DESIGN.md §9 has the recovery path." >&2
    exit 1
fi
