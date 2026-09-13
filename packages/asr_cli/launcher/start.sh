#!/bin/sh
# fushi-subs: start the server and open the web UI. Ctrl+C to stop.
cd "$(dirname "$0")" || exit 1
exec ./fushi-subs serve --open
