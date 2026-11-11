#!/usr/bin/env bash
# A game's benchmark (tools/perf_bench.tscn, a DotGamePerfBench) on a GPU box, windowed with real rendering (gpu.sh run: Xvfb +
# Vulkan on the NVIDIA card), and its per-system table against a reference profile. A game's tools/perf_bench.sh is
#   exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_perf_bench.sh" "$@"
# (set PERF_BENCH_REF first for the game's own reference profile). Run as gamedev, from a checkout:
#   tools/perf_bench.sh [--box staging02] [--headless] [--tag T] [--ref owner.json] [-- perf_bench args]
#   tools/perf_bench.sh --ab DIR_A DIR_B [-n 3] [--box staging02] [-- perf_bench args]
# --ab runs A,B,A,B... (n each) on one pinned box and prints per-system mean deltas.
# A run whose world was inert (nodes_added ~0: no match, no fights) is flagged WARN, and the summary prints INVALID and exits 3;
# --ab will not rank an inert side. PERF_BENCH_INERT_PER_TICK (default 0.05 nodes per tick) sets the limit.
# DIR may carry extra bench args after "::", e.g. ~/wt/game-arena-x::--bots 15.
set -euo pipefail

here=$(cd "$(dirname "$0")/../../.." && pwd)
self=$(dirname "$0")
gpu=${GPU_SH:-/home/gamedev/godot/dot-bootstrap/tools/gpu.sh}
box=staging02
headless=0
tag=""
ref=${PERF_BENCH_REF:-}
logs=${PERF_BENCH_LOGS:-/home/gamedev/perf-bench}
ab=0 n=3 dir_a="" dir_b=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--box) box=$2; shift 2 ;;
		--headless) headless=1; shift ;;
		--tag) tag=$2; shift 2 ;;
		--ref) ref=$2; shift 2 ;;
		--ab) ab=1; dir_a=$2; dir_b=$3; shift 3 ;;
		-n) n=$2; shift 2 ;;
		--) shift; break ;;
		*) echo "perf_bench: unknown option $1" >&2; exit 2 ;;
	esac
done
mkdir -p "$logs"

# One run of the checkout $1 (extra bench args after ::) on $box; prints the log path.
run_one() {
	local spec=$1 label=$2 dir extra=() log
	shift 2
	dir=${spec%%::*}
	[[ $spec == *::* ]] && read -ra extra <<< "${spec#*::}"
	dir=$(cd "$dir" && pwd)
	log="$logs/$(date +%Y%m%d-%H%M%S)-$box-$(basename "$dir")-$label$([[ $headless == 1 ]] && echo -headless).log"
	local hl=()
	[[ $headless == 1 ]] && hl=(--headless)
	echo "perf_bench: $label on $box: $(basename "$dir") ${extra[*]:-} -> $log" >&2
	# gpu.sh takes a project under GODOT_ROOT by name: the checkout's parent and its own name.
	GODOT_ROOT=$(dirname "$dir") GPU_BOX=$box GPU_TIMEOUT=${GPU_TIMEOUT:-900} \
		"$gpu" run "$(basename "$dir")" "${hl[@]}" res://tools/perf_bench.tscn -- --tag "$label" "$@" "${extra[@]}" \
		> "$log" 2>&1 || echo "perf_bench: run exited $? (see $log)" >&2
	grep -q '^PERF_BENCH_REPORT ' "$log" || { echo "perf_bench: no report in $log" >&2; tail -20 "$log" >&2; return 1; }
	# A dead world (nobody fought) gives timings that read as a speedup: say so at once, per run (the table below
	# then exits 3 / INVALID, and --ab will not rank it).
	python3 "$self/dot_game_perf_bench_compare.py" --check "$log" | grep -a 'WARN' | sed 's/^/perf_bench: /' >&2 || true
	echo "$log"
}

if [[ $ab == 0 ]]; then
	log=$(run_one "$here" "${tag:-bench}" "$@")
	if [[ -n $ref ]]; then
		python3 "$self/dot_game_perf_bench_compare.py" "$ref" "$log"
	else
		echo "perf_bench: no reference profile (PERF_BENCH_REF / --ref): report only, in $log"
		grep -h '^PERF_BENCH_SIDECAR ' "$log" | cut -c1-600
		python3 "$self/dot_game_perf_bench_compare.py" --check "$log"
	fi
	exit 0
fi

runs=()
for ((i = 1; i <= n; i++)); do
	runs+=("A=$(run_one "$dir_a" A "$@")")
	runs+=("B=$(run_one "$dir_b" B "$@")")
done
python3 "$self/dot_game_perf_bench_compare.py" --ab "${runs[@]}"
