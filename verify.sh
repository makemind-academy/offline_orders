#!/bin/bash
# offline-orders — verified in AppPlayer. Prerequisites: tools/appplayer.py header.
set -euo pipefail
cd "$(dirname "$0")"
echo "   [1/2] pad_server, till_server (dart analyze)"
( cd pad_server && dart pub get >/dev/null && dart analyze | tail -1 )
( cd till_server && dart pub get >/dev/null && dart analyze | tail -1 )
echo "   [2/2] open in AppPlayer, kill the till, take orders, bring it back"
rm -f captures/*.png pad_server/outbox.json till_server/ledger.json
python3 verify.py
COUNT=$(ls captures/*.png | wc -l | tr -d ' ')
[ "$COUNT" -eq 3 ] || { echo "   expected 3 captures, got $COUNT"; exit 1; }
