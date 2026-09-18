#!/usr/bin/env bash
#
# Measures the liveness signals for whatever is in front of the camera.
#
#   ./spoof-check.sh live     you, sitting normally
#   ./spoof-check.sh phone    a photo or video of you on a phone screen
#   ./spoof-check.sh print    a printed photograph of you
#
# Nothing is unlocked and nothing is installed: this asks for the inert
# `de.faceunlock.probe` right and reads the signals out of the log. Hold the
# target steady, filling roughly the same part of the frame a real face would.
set -uo pipefail
cd "$(dirname "$0")"

LABEL="${1:-live}"
echo "==> Measuring: $LABEL"
echo "    Hold steady for about ten seconds."
START=$(/bin/date "+%Y-%m-%d %H:%M:%S")
./build/authprobe 3 >/dev/null 2>&1
sleep 1

echo
/usr/bin/log show --start "$START" \
    --predicate 'subsystem == "de.faceunlock.mac" AND category == "Liveness"' \
    --info --debug 2>/dev/null \
  | /usr/bin/grep "signals n=" | /usr/bin/sed -E 's/.*signals /  /' | /usr/bin/tail -6

echo
/usr/bin/log show --start "$START" --predicate 'subsystem == "de.faceunlock.mac"' --info 2>/dev/null \
  | /usr/bin/grep "purpose=challenge" \
  | /usr/bin/sed -E 's/.*verdict=([a-z]+).*duration=([0-9.]+)s bestScore=([0-9.]+).*liveness=([0-9.]+).*/  \1  \2s  identity=\3  liveness=\4/' \
  | /usr/bin/tail -3
echo
echo "    (a genuine face should score high on iso/shade/spec; a screen or print"
echo "     should not — that gap is what the floor is meant to sit inside)"
