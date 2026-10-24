#!/bin/bash
# Avatar loadouts over real ENet: a fake backbone, a dedicated server and two headless clients,
# each its own process. Exit 0 only when both clients pass and nothing wrote a script error.
#   heavy -- tools/avatar_two_peer.sh
set -u
cd "$(dirname "$0")/.." || exit 2
LOG=.godot/test-logs/avatar_two_peer
mkdir -p "$LOG"
PORT=$((24000 + RANDOM % 4000))
BB=$((PORT + 1))
SCENE=res://examples/avatar_two_peer.tscn

python3 -I - "$BB" > "$LOG/backbone.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
AVATARS = {
    "keyA0000": {"actions": {"EMOTE": [{"builtin": "dance"}], "POSE": [], "GESTURE": []}},
    "keyB0000": {"actions": {
        "EMOTE": [{"contentId": "action/12/3", "clip": "Wave_Big", "loop": True, "fileUrl": "https://elsewhere.invalid/x.glb"}],
        "POSE": [],
        "GESTURE": [{"builtin": "point"}]}},
}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if self.headers.get("Authorization") != "Bearer two-peer-token":
            self.send_response(401); self.end_headers(); return
        if len(parts) == 3 and parts[0] == "user" and parts[2] == "avatar" and parts[1] in AVATARS:
            body = json.dumps(AVATARS[parts[1]]).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
BBPID=$!
sleep 0.5

timeout 50 godot --headless --path . "$SCENE" -- --role=server --port="$PORT" --backbone="http://127.0.0.1:$BB" > "$LOG/server.log" 2>&1 &
SPID=$!
sleep 2
timeout 50 godot --headless --path . "$SCENE" -- --role=a --port="$PORT" > "$LOG/a.log" 2>&1 &
APID=$!
sleep 2
timeout 50 godot --headless --path . "$SCENE" -- --role=b --port="$PORT" > "$LOG/b.log" 2>&1
B=$?
wait "$APID"; A=$?
wait "$SPID"; S=$?
kill "$BBPID" 2>/dev/null

for f in server a b; do
    echo "--- $f (exit)"
    grep -E "two-peer|SCRIPT ERROR|ERROR:" "$LOG/$f.log"
done
echo "--- backbone"
grep -E '"GET' "$LOG/backbone.log"
ERRS=$(grep -lE "SCRIPT ERROR|Parse Error" "$LOG"/*.log | wc -l)
echo "exits: server=$S a=$A b=$B, files with script errors: $ERRS"
[ "$A" = 0 ] && [ "$B" = 0 ] && [ "$S" = 0 ] && [ "$ERRS" = 0 ]
