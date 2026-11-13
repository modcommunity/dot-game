
extends "dot_game_perf_bench.gd"

## DotGamePerfBench for a game with no bench subclass of its own: `--scene res://game/x.tscn` names the client scene; the game's own default map, mode and bots are what run.
## Run as res://addons/dot_game/qa/dot_game_perf_bench_any.tscn (dot-game's tools/perf_bench.sh does when PERF_BENCH_SCENE says so).


func _configure() -> void:
	var user_args := OS.get_cmdline_user_args()
	for i in range(user_args.size() - 1):
		if user_args[i] == "--scene":
			client_scene = user_args[i + 1]
	bots = 15
	warmup = 8.0
	seconds = 20.0
