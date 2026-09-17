#!/usr/bin/env bash
# Stage 1 check for the lock-screen work: does the running app answer an
# identity challenge with a correct verdict over the local socket?
#
# Nothing privileged is installed. Launch the app first with the responder on:
#   ./Scripts/run-local.sh --identity
# then run this. It sends one challenge with a random nonce and prints the
# verdict; the app runs the full recognition pipeline (model, per-user
# threshold, liveness) and replies OK or NO for that nonce.
set -euo pipefail
SOCKET="${1:-/tmp/faceunlock-identity.sock}"

if [ ! -S "$SOCKET" ]; then
    echo "No socket at $SOCKET."
    echo "Launch the app first:  ./Scripts/run-local.sh --identity"
    exit 1
fi

NONCE="check-$(date +%s)-$RANDOM"
echo "Sending challenge (nonce $NONCE). Look at the camera for a few seconds…"
REPLY="$(printf 'CHALLENGE %s\n' "$NONCE" | nc -U -w 25 "$SOCKET" || true)"
REPLY="$(printf '%s' "$REPLY" | tr -d '\r\n')"

echo "Reply: ${REPLY:-<none>}"
case "$REPLY" in
    "OK $NONCE") echo "PASS — recognised you, and the nonce matched." ;;
    "NO $NONCE") echo "Did NOT recognise you (or you were not looking). Nonce matched, channel works." ;;
    "")          echo "No reply — is the app running with --identity?" ;;
    *)           echo "Unexpected reply — the channel works but the response was not understood." ;;
esac
