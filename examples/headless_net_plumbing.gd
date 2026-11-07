extends Node

## DotGameRequest and DotGamePaths: the wire round trip, kind validation, and rebasing onto a mount.

const CHECKS := 12

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class Ask:
	extends DotGameRequest

	func _type_name() -> StringName:
		return &"test.request"

	func _kind_count() -> int:
		return 4


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	print("dot-game: net plumbing")
	var a := Ask.new(2, PackedByteArray([1, 2, 3]))
	_check(a._type_name() == &"test.request", "the subclass names the message")
	_check(a._validate().ok, "a kind inside the count validates")
	_check(not Ask.new(4)._validate().ok, "a kind at the count is refused")
	_check(not Ask.new(-1)._validate().ok, "a negative kind is refused")
	_check(Ask.new().kind == 0 and Ask.new().body.is_empty(), "a bare new() works for the registry")
	_check(DotGameRequest.fits(32) and not DotGameRequest.fits(33), "fits is the kind bits")
	var w := DotNetWriter.new()
	a._write(w)
	var b := Ask.new()
	b._read(DotNetReader.new(w.to_bytes()))
	_check(b.kind == 2 and b.body == PackedByteArray([1, 2, 3]), "kind and body round-trip")
	_check(b.reader().read_uint(8) == 1, "reader reads the body")

	var mount := "res://dot_cloud/me/g/1.0.0"
	_check(DotGamePaths.rebase_onto("res://maps/x.json", mount) == mount + "/maps/x.json", "a res path moves onto the mount")
	_check(DotGamePaths.rebase_onto(mount + "/maps/x.json", mount) == mount + "/maps/x.json", "rebasing is idempotent")
	_check(DotGamePaths.rebase_onto("user://s.cfg", mount) == "user://s.cfg", "a user path is untouched")
	_check(DotGamePaths.rebase_onto("res://a", "res://") == "res://a", "built in it returns its argument")

	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
