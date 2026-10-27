class_name DotGameCheckSuite
extends Node

## Base for a game's `examples/headless_*.gd` suite: pass/fail counting, `_check`, and a summary that also fails when fewer checks ran than expected.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


## Records one check; returns [param ok] so a caller can skip what depends on it.
func _check(ok: bool, what: String, detail := "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return ok


## Prints the totals and failures, then quits: 1 on a failure or when [param expected] (if not -1) checks did not all run.
func _report(expected := -1) -> void:
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if expected >= 0 and _passed + _failed != expected:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, expected])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
