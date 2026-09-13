#!/bin/sh
# fushi-subs: start the server and open the web UI. Close this window (Ctrl+C) to stop.
cd "$(dirname "$0")" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null
exec ./fushi-subs serve --open
