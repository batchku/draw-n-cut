#!/bin/bash
# Live-watch DrawNCut on the connected iPhone: relaunches the app with its
# console attached, so every in-app [trace] diagnostic line streams here
# while the user interacts with the phone.
#
# Usage: scripts/watch-device.sh [device-id]
set -euo pipefail
DEVICE="${1:-B062F44F-9E75-5CC0-8707-0CF2E4BFA5CF}"
exec xcrun devicectl device process launch --console --terminate-existing \
    --device "$DEVICE" com.irllabs.drawncut
