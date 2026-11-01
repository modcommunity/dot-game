#!/usr/bin/env bash
# Captures short looping clips of the animations that changed since the last posted review and files them on the
# nightly panel's /reviews page (before = the clip posted last time, after = the new one, plus a filmstrip sheet).
# The shared script (dot-game/tools); a game's tools/capture_reviews.sh cds to its root and execs it, and
# tools/qa.conf supplies three functions:
#   review_items                  print the item ids (a weapon, a gait), one per line
#   review_fingerprint ITEM       print every input that decides how ITEM animates (files, rows); a changed hash = recapture
#   review_look KIND              (optional) one line on what to look for in a clip of that kind
#   review_capture OUTDIR ITEM... on a GPU box, write OUTDIR/<item>__<kind>.mp4 (kinds: reload, fire, walk, ...)
#
#   tools/capture_reviews.sh                 every item whose fingerprint changed since the last posted capture
#   tools/capture_reviews.sh --all           every item
#   tools/capture_reviews.sh pistol smg      these items, changed or not
#   tools/capture_reviews.sh --dry-run       list what would be captured
#   tools/capture_reviews.sh --no-post       capture into .godot/review-clips/ only
# State (the last posted clips, which become the next "before", and the fingerprints) is in $REVIEW_STATE
# (default ~/.local/state/dot-reviews/<game>). Key of the review: <game>-anim-<date>. Exit 1 if a clip is missing.
set -uo pipefail
SHARED=$(cd "$(dirname "$0")" && pwd)
ROOT=$PWD
GAME=$(basename "$ROOT")
[ -f tools/qa.conf ] || { echo "reviews: no tools/qa.conf in $ROOT" >&2; exit 2; }
# shellcheck disable=SC1091
. tools/qa.conf
declare -F review_items >/dev/null || { echo "reviews: tools/qa.conf has no review_items" >&2; exit 2; }

all=0 post=1 dry=0 items=()
for a in "$@"; do
    case $a in
        --all) all=1 ;;
        --no-post) post=0 ;;
        --dry-run) dry=1 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *) items+=("$a") ;;
    esac
done
state=${REVIEW_STATE:-$HOME/.local/state/dot-reviews}/$GAME
work=.godot/review-clips
mkdir -p "$state" "$work"

declare -A sha reason
want=()
mapfile -t known < <(review_items)
[ ${#items[@]} -gt 0 ] && forced=1 || { forced=0; items=("${known[@]}"); }
for it in "${items[@]}"; do
    sha[$it]=$(review_fingerprint "$it" | sha1sum | cut -c1-12)
    old=$(cat "$state/$it.sha" 2>/dev/null || true)
    if [ "$forced" = 1 ] || [ "$all" = 1 ]; then want+=("$it"); reason[$it]="recaptured on request"
    elif [ -z "$old" ]; then want+=("$it"); reason[$it]="first capture"
    elif [ "$old" != "${sha[$it]}" ]; then want+=("$it"); reason[$it]="animation inputs changed ($old -> ${sha[$it]})"
    fi
done
echo "reviews: ${#want[@]} of ${#items[@]} items to capture: ${want[*]:-none}"
[ ${#want[@]} -eq 0 ] || [ "$dry" = 1 ] && exit 0

rm -rf "${work:?}"/*
review_capture "$work" "${want[@]}" || echo "reviews: capture reported a failure, posting what exists" >&2
shopt -s nullglob
[ -n "$(echo "$work"/*.mp4)" ] || { echo "reviews: no clips produced" >&2; exit 1; }
for it in "${want[@]}"; do
    f=("$work/${it}__reload.mp4"); [ -f "${f[0]}" ] || f=("$work/${it}__"*.mp4)
    [ -f "${f[0]}" ] && bash addons/dot_core/tools/dot_filmstrip.sh "${f[0]}" "$work/$it" --cols 4 --rows 3 --width 320 >/dev/null
done
[ "$post" = 1 ] || { echo "reviews: clips in $work (not posted)"; exit 0; }

poster=$(mktemp); trap 'rm -f "$poster"' EXIT
ssh -o BatchMode=yes dev01 'cat ~/stack/nightly/scripts/review-post.sh' > "$poster" && chmod +x "$poster" || { echo "reviews: cannot fetch review-post.sh" >&2; exit 1; }
key="$GAME-anim-$(date +%F)"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
"$poster" new "$key" "$GAME animation clips $(date +%F) (changed items, before/after)" >/dev/null || exit 1
fail=0
for it in "${want[@]}"; do
    posted=0
    for clip in "$work/${it}__"*.mp4; do
        kind=${clip##*__}; kind=${kind%.mp4}
        note="${reason[$it]}; $GAME@$commit"
        extra=()
        if grep -q -- --look "$poster"; then
            m=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames,duration,width,height -of csv=p=0 "$clip" 2>/dev/null)
            IFS=, read -r w h dur nf <<< "$m"
            extra=(--look "$(review_look "$kind" 2>/dev/null || echo "Check the motion reads cleanly: no pops, no sliding, loops back to the start pose.")"
                   --metrics "{\"frames\":\"$nf\",\"seconds\":\"$(printf "%.1f" "${dur:-0}")\",\"size\":\"${w}x${h}\"}")
        fi
        if [ -f "$state/${it}__$kind.mp4" ]; then
            "$poster" media "$key" "$it" "$state/${it}__$kind.mp4" --slot clip --variant before --label "$kind" --title "$kind before" "${extra[@]}" >/dev/null || fail=1
        else
            note="$note; no earlier clip to compare"
        fi
        "$poster" media "$key" "$it" "$clip" --slot clip --variant after --label "$kind" --title "$kind after" --note "$note" "${extra[@]}" >/dev/null && posted=1 || fail=1
    done
    [ -f "$work/${it}_sheet.png" ] && { "$poster" media "$key" "$it" "$work/${it}_sheet.png" --slot filmstrip --variant after --label "reload" >/dev/null || fail=1; }
    if [ "$posted" = 1 ]; then
        for clip in "$work/${it}__"*.mp4; do cp "$clip" "$state/"; done
        echo "${sha[$it]}" > "$state/$it.sha"
    fi
done
echo "reviews: posted to $key ($([ $fail = 0 ] && echo ok || echo "with failures")): ${QA_URL:-http://x-tmc-dev01:3010}/reviews"
exit $fail
