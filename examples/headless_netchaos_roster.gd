extends Node

## DotGameNetchaosClient._find_game: the game node is found by `game`, by any other variable that has players(), and by
## the `game` group; a client with none gives null (playground names its own `playground`).

const CHECKS := 7

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class World:
	extends Node
	func players() -> Array:
		return [1]


class ByGame:
	extends Node
	var game: Node = null


class ByOther:
	extends Node
	var playground: Node = null
	var unrelated: Node = null


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	var find := DotGameNetchaosClient._find_game
	_check(find.call(null) == null, "null client gives null")
	var world := World.new()
	add_child(world)
	var a := ByGame.new()
	a.game = world
	add_child(a)
	_check(find.call(a) == world, "the game property")
	var b := ByOther.new()
	b.unrelated = Node.new()
	b.playground = world
	add_child(b)
	_check(find.call(b) == world, "a differently named variable that has players()")
	_check(find.call(b) != b.unrelated, "a node without players() is not the game")
	var c := ByOther.new()
	add_child(c)
	_check(find.call(c) == null, "no game gives null")
	var d := ByOther.new()
	d.unrelated = Node.new()
	add_child(d)
	_check(find.call(d) == null, "a variable without players() gives null")
	world.add_to_group(&"game")
	_check(find.call(c) == world, "the game group")
	var total := _passed + _failed
	print("headless_netchaos_roster: %d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  FAIL: ", f)
	if total != CHECKS:
		print("  check count %d != %d" % [total, CHECKS])
	get_tree().quit(0 if _failed == 0 and total == CHECKS else 1)
