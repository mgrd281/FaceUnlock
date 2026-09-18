#!/usr/bin/env bash
#
# Installs the FaceUnlock lock-screen components.
#
#   sudo ./install.sh                        stage 0 — the lock screen is NOT touched
#   sudo ./install.sh --enable-lock-screen   stage 1 — adds the face branch to the real right
#   sudo ./install.sh --app /path/FaceUnlock.app
#
# Stage 0 installs the broker, the mechanism, and a custom right
# (de.faceunlock.probe) that guards nothing. It is safe to run and safe to leave
# installed: nothing in the login or unlock path references it.
#
# Stage 1 adds our sub-rule to system.login.screensaver. It *appends* to whatever
# is already there — this Mac already carries another vendor's plugin in that
# rule, and overwriting it would break their product. Read §8 of DESIGN.md
# before running it, and make sure uninstall.sh works first.
#
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT_DIR="/Library/Application Support/FaceUnlock"
PLUGIN_DEST="/Library/Security/SecurityAgentPlugins/FaceUnlock.bundle"
DAEMON_DEST="/Library/PrivilegedHelperTools/de.faceunlock.daemon"
DAEMON_PLIST="/Library/LaunchDaemons/de.faceunlock.daemon.plist"
DAEMON_LABEL="de.faceunlock.daemon"
PROBE_RIGHT="de.faceunlock.probe"
FACE_RULE="de.faceunlock.screensaver"
REAL_RIGHT="system.login.screensaver"

ENABLE_LOCK_SCREEN=no
APP_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --enable-lock-screen) ENABLE_LOCK_SCREEN=yes; shift ;;
        --app) APP_PATH="${2:-}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "This must run as root: sudo ./install.sh" >&2; exit 1; }

# The components sit in one of two places: `build/` while developing in the
# spike directory, or beside this script once it ships inside FaceUnlock.app.
# One script serves both so the shipped installer is the tested installer.
if [ -e "build/faceunlockd" ] && [ -e "build/FaceUnlock.bundle" ]; then
    COMPONENTS="build"
elif [ -e "faceunlockd" ] && [ -e "FaceUnlock.bundle" ]; then
    COMPONENTS="."
else
    echo "Cannot find faceunlockd and FaceUnlock.bundle." >&2
    echo "In the source tree, run ./build.sh first." >&2
    exit 1
fi
DAEMON_SRC="$COMPONENTS/faceunlockd"
PLUGIN_SRC="$COMPONENTS/FaceUnlock.bundle"

# ---------------------------------------------------------------- locate the app
if [ -z "$APP_PATH" ]; then
    for candidate in \
        "../../.." \
        "/Applications/FaceUnlock.app" \
        "../../build/local/Build/Products/Debug/FaceUnlock.app" \
        "../../build/local/Build/Products/Release/FaceUnlock.app"
    do
        # The first candidate is the enclosing app when this script ships inside
        # it (Contents/Library/LockScreenUnlock/install.sh); it is only an app if
        # it actually looks like one.
        case "$candidate" in
            "../../..") [ -d "$candidate/Contents/MacOS" ] || continue ;;
        esac
        if [ -d "$candidate" ]; then APP_PATH="$candidate"; break; fi
    done
fi
[ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] || {
    echo "Could not find FaceUnlock.app. Pass --app /path/to/FaceUnlock.app." >&2
    echo "The broker pins its peers by code signature, so it needs the real app." >&2
    exit 1
}
echo "==> App: $APP_PATH"

# ------------------------------------------------- back up BEFORE any write
# Unconditional, every run, before anything else is touched. A failure here
# aborts the install rather than proceeding without a way back.
mkdir -p "$SUPPORT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$SUPPORT_DIR/authdb-backup-$STAMP.plist"
if ! security authorizationdb read "$REAL_RIGHT" > "$BACKUP" 2>/dev/null; then
    echo "Could not read $REAL_RIGHT to back it up. Aborting." >&2
    rm -f "$BACKUP"
    exit 1
fi
chmod 600 "$BACKUP"
echo "==> Backed up $REAL_RIGHT to $BACKUP"

# --------------------------------------------------- derive peer requirements
# The requirement is a deployment fact, not a compile-time constant: an ad-hoc
# signed local build and a Developer ID release have different ones and both
# must work. Deriving them from the binaries we are actually installing is
# trust-on-first-use; for a release, set FACEUNLOCK_TEAM_ID to pin the team
# instead of the exact code.
# Absolute paths: this runs under sudo, where PATH is reset by secure_path.
# The trailing `/* exists */` that codesign emits is a comment. The requirement
# language allows it, but xpc_connection_set_peer_code_signing_requirement uses
# its own parser and there is nothing to gain by finding out the hard way, so it
# is stripped here.
requirement_for() {
    codesign -d -r- "$1" 2>/dev/null \
        | /usr/bin/sed -n 's/^designated => //p' \
        | /usr/bin/sed 's|/\*[^*]*\*/||g; s/  */ /g; s/ *$//'
}

# The process that hosts our mechanism is Apple's SecurityAgent, not our own
# bundle: a peer code signing requirement validates the process at the other end
# of the connection, and a bundle loaded into another process never appears as a
# peer in its own right. This is fixed rather than derived, because it describes
# Apple's code and not ours.
HOST_REQ='anchor apple and (identifier "com.apple.SecurityAgentHelper.arm64" or identifier "com.apple.SecurityAgentHelper.x86_64" or identifier "com.apple.SecurityAgent" or identifier "com.apple.authd")'

if [ -n "${FACEUNLOCK_TEAM_ID:-}" ]; then
    echo "==> Pinning peers to Team ID $FACEUNLOCK_TEAM_ID"
    APP_REQ="identifier \"de.faceunlock.mac\" and anchor apple generic and certificate leaf[subject.OU] = \"$FACEUNLOCK_TEAM_ID\""
    BROKER_REQ="identifier \"de.faceunlock.daemon\" and anchor apple generic and certificate leaf[subject.OU] = \"$FACEUNLOCK_TEAM_ID\""
else
    echo "==> Deriving peer requirements from the installed code (trust on first use)"
    echo "    Set FACEUNLOCK_TEAM_ID for a Developer ID build to pin the team instead."
    APP_REQ="$(requirement_for "$APP_PATH")"
    BROKER_REQ="$(requirement_for "$DAEMON_SRC")"
fi

for pair in "app:$APP_REQ" "broker:$BROKER_REQ"; do
    if [ -z "${pair#*:}" ]; then
        echo "Could not derive a code requirement for ${pair%%:*}. Is it signed?" >&2
        exit 1
    fi
done

# A requirement that does not match the code it describes would fail only at the
# lock screen, so it is checked here instead.
if ! codesign --verify -R="$HOST_REQ" \
        /System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/XPCServices/SecurityAgentHelper-arm64.xpc \
        2>/dev/null \
   && ! codesign --verify -R="$HOST_REQ" \
        /System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent \
        2>/dev/null
then
    echo "The SecurityAgent host requirement matches neither SecurityAgentHelper nor" >&2
    echo "SecurityAgent on this macOS version. Aborting rather than installing a" >&2
    echo "broker that would refuse every challenge." >&2
    exit 1
fi

# ----------------------------------------------------------------- install
echo "==> Installing the broker"
mkdir -p /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$DAEMON_SRC" "$DAEMON_DEST"

echo "==> Installing the mechanism"
rm -rf "$PLUGIN_DEST"
mkdir -p /Library/Security/SecurityAgentPlugins
cp -R "$PLUGIN_SRC" "$PLUGIN_DEST"
chown -R root:wheel "$PLUGIN_DEST"
chmod -R go-w "$PLUGIN_DEST"

# Verify what we just installed, at its final path, rather than what we built.
if ! codesign --verify --strict "$PLUGIN_DEST" 2>/dev/null; then
    echo "The installed bundle does not verify. Removing it and aborting." >&2
    rm -rf "$PLUGIN_DEST"
    exit 1
fi

echo "==> Writing peer requirements"
cat > "$SUPPORT_DIR/peers.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppRequirement</key>
	<string>$(printf '%s' "$APP_REQ" | /usr/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>
	<key>PluginHostRequirement</key>
	<string>$(printf '%s' "$HOST_REQ" | /usr/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>
	<key>BrokerRequirement</key>
	<string>$(printf '%s' "$BROKER_REQ" | /usr/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>
</dict>
</plist>
PLIST
chown root:wheel "$SUPPORT_DIR/peers.plist"
chmod 644 "$SUPPORT_DIR/peers.plist"
plutil -lint "$SUPPORT_DIR/peers.plist" >/dev/null || {
    echo "peers.plist is malformed. Aborting." >&2; exit 1; }

echo "==> Installing the LaunchDaemon"
# /Library/LaunchDaemons exists on any real macOS install; created here only so
# the script is self-contained, like the two directories above.
mkdir -p "$(dirname "$DAEMON_PLIST")"
cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$DAEMON_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DAEMON_DEST</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>de.faceunlock.broker.agent</key>
		<true/>
		<key>de.faceunlock.broker.asker</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"

launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
launchctl bootstrap system "$DAEMON_PLIST"
echo "==> Broker running"

# ------------------------------------------------------ the stage-0 right
echo "==> Creating $PROBE_RIGHT (guards nothing)"
security authorizationdb write "$PROBE_RIGHT" <<'PLIST' >/dev/null 2>&1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>class</key>
	<string>evaluate-mechanisms</string>
	<key>comment</key>
	<string>FaceUnlock stage-0 probe. Guards nothing; exists only to exercise the mechanism without touching login.</string>
	<key>mechanisms</key>
	<array>
		<string>FaceUnlock:present</string>
	</array>
	<key>shared</key>
	<false/>
	<key>tries</key>
	<integer>1</integer>
</dict>
</plist>
PLIST

# ------------------------------------------------------ stage 1, on request
if [ "$ENABLE_LOCK_SCREEN" = "yes" ]; then
    echo "==> Creating the $FACE_RULE sub-rule"
    security authorizationdb write "$FACE_RULE" <<'PLIST' >/dev/null 2>&1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>class</key>
	<string>evaluate-mechanisms</string>
	<key>comment</key>
	<string>FaceUnlock: asks whether the enrolled owner of this session is in front of the camera right now. Denying falls through to the password branch.</string>
	<key>mechanisms</key>
	<array>
		<string>FaceUnlock:present</string>
	</array>
	<key>shared</key>
	<true/>
	<key>tries</key>
	<integer>1</integer>
</dict>
</plist>
PLIST

    echo "==> Composing $REAL_RIGHT (appending, never overwriting)"
    # Staged and validated before writing, for the same reason as in
    # uninstall.sh: a composer that refuses must not still result in a write.
    COMPOSED="$(mktemp)"
    if ! { security authorizationdb read "$REAL_RIGHT" 2>/dev/null \
            | python3 compose-rule.py add "$FACE_RULE" > "$COMPOSED"; } \
        || [ ! -s "$COMPOSED" ] \
        || ! plutil -lint "$COMPOSED" >/dev/null 2>&1 \
        || ! security authorizationdb write "$REAL_RIGHT" < "$COMPOSED" >/dev/null 2>&1
    then
        rm -f "$COMPOSED"
        echo "Composing the rule failed. $REAL_RIGHT is unchanged." >&2
        echo "The backup is at $BACKUP" >&2
        exit 1
    fi
    rm -f "$COMPOSED"
    echo
    echo "    Face unlock is now in the lock-screen path."
    security authorizationdb read "$REAL_RIGHT" 2>/dev/null | python3 compose-rule.py show
fi

echo
echo "Installed."
echo
if [ "$ENABLE_LOCK_SCREEN" = "yes" ]; then
    echo "  Lock the screen (Ctrl-Cmd-Q) to try it. Your password still works:"
    echo "  it is a separate branch of the same rule and nothing we do can remove it."
else
    echo "  Stage 0. The lock screen is untouched. Exercise the path with:"
    echo "      ./build/authprobe 3"
    echo
    echo "  When that is green, and uninstall.sh has been tested:"
    echo "      sudo ./install.sh --enable-lock-screen"
fi
echo
echo "  Remove everything:  sudo ./uninstall.sh"
