#!/bin/bash
# Dev helper: Scripts/snap.sh out.png [paths...]  — launches the built app, snapshots its window, quits.
OUT="$1"; shift
JUXTA_SNAPSHOT="$OUT" JUXTA_SNAPSHOT_QUIT=1 JUXTA_SNAPSHOT_DELAY="${DELAY:-2.5}" "$(dirname "$0")/../build/Juxta.app/Contents/MacOS/Juxta" "$@" &
PID=$!
for i in $(seq 1 100); do sleep 0.25; kill -0 $PID 2>/dev/null || break; done
kill $PID 2>/dev/null; true
