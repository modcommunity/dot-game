extends Node

## DotGameNoblock: cfg layers, cvars, the pair answer a body's pair_fn gets, strict refusal, workbench edit.
##
## [codeblock]
## godot --headless --path . res://examples/headless_noblock.tscn
## [/codeblock]

const ROOT := "res://examples/fixtures/noblock/"
const CHECKS := 20

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class Body:
	extends RefCounted
	var pair_fn: Callable = Callable()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _side(id: Variant) -> Variant:
	return "red" if int(id) in [1, 2] else ("blue" if int(id) == 3 else "")


func _run() -> void:
	print("dot-game: noblock")
	_check(DotGameNoblock.available(), "dot-team is linked")
	var plain := DotGameNoblock.create("tg", _side, PackedStringArray([ROOT + "none"]), true)
	_check(plain.ok, "defaults load with no files")
	var nb: DotGameNoblock = plain.value
	var body := Body.new()
	nb.feed(body)
	_check(body.pair_fn.is_valid(), "feed sets pair_fn")
	_check(not body.pair_fn.call(1, 2), "teammates pass by default")
	_check(body.pair_fn.call(1, 3), "enemies block by default")
	_check(body.pair_fn.call(1, 9), "a player with no side is an enemy")

	var console := DotConsole.new()
	add_child(console)
	var bound := nb.bind(console.cvar, console)
	_check(bound.ok, "bind succeeds")
	_check(console.get_string("mp_teamblock") == "0" and console.get_string("mp_enemyblock") == "1", "cvars start at the config")
	_check(console.find_cvar("mp_teamblock").has_flag(DotConVar.FLAG_REPLICATED), "mp_teamblock is replicated")
	_check(console.find_cvar("mp_blockstate").has_flag(DotConVar.FLAG_REPLICATED), "mp_blockstate is replicated")
	console.set_cvar("mp_teamblock", "1")
	_check(body.pair_fn.call(1, 2), "the cvar flips the pair")
	console.set_cvar("mp_teamblock", "0")

	nb.rules.request(1, [0], 0)
	_check(console.get_string("mp_blockstate") != "", "a request publishes mp_blockstate")
	nb.rules.forget(1)
	_check(console.get_string("mp_blockstate") == "", "forget drops a leaver's request")

	nb.binder.config.set(&"enemy_block", false)
	nb.binder._assign("enemy_block", false, "workbench")
	nb.binder._assign("enemy_block", true, "workbench")
	_check(console.get_string("mp_enemyblock") == "1", "a workbench edit reaches the cvar")
	nb.binder._assign("enemy_block", false, "workbench")
	_check(console.get_string("mp_enemyblock") == "0" and not body.pair_fn.call(1, 3), "and the pair")

	var ok := DotGameNoblock.create("tg", _side, PackedStringArray([ROOT + "ok"]), true)
	_check(ok.ok, "a cfg file loads")
	var cfg: Object = (ok.value as DotGameNoblock).rules.get(&"config")
	_check(cfg.get(&"team_block") == true and cfg.get(&"command_mode") == 1, "cfg values land in the config")
	_check((ok.value as DotGameNoblock).binder.source_of("team_block") != "", "the layer is recorded")
	var bad := DotGameNoblock.create("tg", _side, PackedStringArray([ROOT + "bad"]), true)
	_check(not bad.ok, "an unknown key refuses the boot when strict")
	var lax := DotGameNoblock.create("tg", _side, PackedStringArray([ROOT + "bad"]), false)
	_check(lax.ok, "and only logs when not strict")

	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
