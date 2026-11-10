extends Node

## DotGameShardArgs: the shard name, the merge logs, the round-robin slice, the missing-log and sections-entered readers.

const CHECKS := 12

var _passed := 0
var _failed := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)


func _ready() -> void:
	var S := DotGameShardArgs
	_check(S.shard(PackedStringArray(["--shard", "m2"])) == "m2", "--shard NAME names the shard")
	_check(S.shard(PackedStringArray()) == "", "no --shard is the whole suite")
	_check(S.shard(PackedStringArray(["--shard"])) == "", "a trailing --shard names nothing")
	_check(not S.is_merge(PackedStringArray(["--shard", "a"])), "a shard run is not a merge")
	_check(S.is_merge(PackedStringArray(["--merge", "a.log"])), "--merge is a merge")
	_check(S.merge_logs(PackedStringArray(["--merge", "a.log", "b.log"])) == PackedStringArray(["a.log", "b.log"]), "the logs follow --merge")
	_check(S.merge_logs(PackedStringArray(["--shard", "a"])).is_empty(), "no logs without --merge")
	var items := ["a", "b", "c", "d", "e"]
	_check(S.slice(items, "m1", 2) == ["b", "d"], "slice deals round-robin: m1 of 2")
	_check(S.slice(items, "", 2) == items, "slice of no shard is everything")
	var base := OS.get_user_data_dir()
	DirAccess.make_dir_recursive_absolute(base)
	var a := base.path_join("shard_args_a.log")
	var b := base.path_join("shard_args_b.log")
	var gone := base.path_join("shard_args_gone.log")
	var f := FileAccess.open(a, FileAccess.WRITE)
	f.store_string("x\n3 sections entered\n")
	f.close()
	f = FileAccess.open(b, FileAccess.WRITE)
	f.store_string("5 sections entered\n")
	f.close()
	_check(S.sections_entered(PackedStringArray([a, b])) == 8, "sections entered add up over the logs")
	_check(S.missing(PackedStringArray([a, gone])) == [gone], "a log not on disk is missing")
	_check(S.sections_entered(PackedStringArray([gone])) == 0, "a missing log enters nothing")
	DirAccess.remove_absolute(a)
	DirAccess.remove_absolute(b)
	if _passed + _failed != CHECKS:
		_failed += 1
		print("FAIL: ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
