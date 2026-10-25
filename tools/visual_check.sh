#!/usr/bin/env bash
# Renders a game's standard shots and compares them to tests/golden/<case>_<shot>.png. The shared script (dot-game/tools);
# a game's tools/visual_check.sh cds to its root and execs it, and tools/qa.conf sets VISUAL_CASES (default cases),
# VISUAL_SHOTS (names, default "overview eye roof") and visual_render CASE (writes screenshots/<case>_<shot>.png).
#
#   tools/visual_check.sh                 every default case
#   tools/visual_check.sh dm_box          one case
#   tools/visual_check.sh --update [CASE] re-record the goldens (look at them first)
#   tools/visual_check.sh --post          also send the result to the nightly panel's /qa (kind visual) through dev01
#
# Frames are 800x450 (RESOLUTION) to keep the goldens small. Tolerances for GPU noise:
# VISUAL_PIXEL_TOL, VISUAL_MAX_PCT, VISUAL_MAX_MEAN (see visual_compare.py). A failing frame
# leaves golden | frame | diff in .godot/test-logs/visual/. GPU_OFFLOAD=0 renders locally.
set -uo pipefail
SHARED=$(cd "$(dirname "$0")" && pwd)
ROOT=$PWD
GAME=$(basename "$ROOT")
[ -f tools/qa.conf ] || { echo "visual: no tools/qa.conf in $ROOT" >&2; exit 2; }
# shellcheck disable=SC1091
. tools/qa.conf
shots=(${VISUAL_SHOTS:-overview eye roof})

update=0
post=0
maps=()
for arg in "$@"; do
    case "$arg" in
        --update) update=1 ;;
        --post) post=1 ;;
        *) maps+=("$arg") ;;
    esac
done
[ ${#maps[@]} -eq 0 ] && maps=(${VISUAL_CASES:?tools/qa.conf must set VISUAL_CASES})

out=.godot/test-logs/visual
mkdir -p "$out" tests/golden
export RESOLUTION="${RESOLUTION:-800x450}"
failed=0
failed_maps=()
total=0

for map in "${maps[@]}"; do
    for shot in "${shots[@]}"; do rm -f "screenshots/${map}_${shot}.png"; done
    if ! visual_render "$map" >"$out/$map.log" 2>&1; then
        echo "FAIL $map: render failed, see $out/$map.log"
        failed=$((failed + 1)); failed_maps+=("$map")
        continue
    fi
    bad=0
    for shot in "${shots[@]}"; do
        frame="screenshots/${map}_${shot}.png"
        golden="tests/golden/${map}_${shot}.png"
        total=$((total + 1))
        if [ ! -s "$frame" ]; then
            echo "FAIL $map $shot: no frame written, see $out/$map.log"
            bad=1
        elif [ $update -eq 1 ]; then
            cp "$frame" "$golden"
        elif [ ! -f "$golden" ]; then
            echo "FAIL $map $shot: no golden $golden; run tools/visual_check.sh --update $map"
            bad=1
        elif ! python3 -I "$SHARED/visual_compare.py" "$golden" "$frame" "$out/${map}_${shot}_diff.png" | tee -a "$out/$map.compare" | grep -v '^ok'; then
            :
        fi
    done
    if [ $update -eq 0 ]; then
        grep -q '^FAIL' "$out/$map.compare" 2>/dev/null && bad=1
        rm -f "$out/$map.compare"
    fi
    if [ $bad -eq 1 ]; then failed=$((failed + 1)); failed_maps+=("$map"); echo "map $map: FAIL"; else echo "map $map: ok"; fi
done

summary="visual: $((${#maps[@]} - failed))/${#maps[@]} maps ok, $total frames$([ $update -eq 1 ] && echo ' (goldens updated)')"
echo "$summary"
if [ $post -eq 1 ] && [ $update -eq 0 ]; then
    # qa-post.sh reads the "visual: N/M maps ok" line and the *_diff.png files; it lives with the panel on dev01.
    log=$out/summary.log; : >"$log"
    for map in ${failed_maps[@]+"${failed_maps[@]}"}; do echo "map $map: FAIL" >>"$log"; done
    echo "$summary" >>"$log"
    tar -C "$out" -cf - summary.log $(cd "$out" && ls *_diff.png 2>/dev/null) \
        | ssh dev01 "d=\$(mktemp -d) && tar -C \$d -xf - && QA_URL=http://127.0.0.1:3010 QA_COMMIT=$(git rev-parse HEAD 2>/dev/null) ~/stack/nightly/scripts/qa-post.sh visual $GAME \$d/summary.log \$d; r=\$?; rm -rf \$d; exit \$r"
fi
[ $failed -eq 0 ]
