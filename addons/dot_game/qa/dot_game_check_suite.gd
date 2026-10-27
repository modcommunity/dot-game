class_name DotGameCheckSuite
extends Node

## Base for a game's `examples/headless_*.gd` suite: pass/fail counting, `_check`, and a summary that also fails when fewer checks ran than expected.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _broken := false


## Records one check; returns [param ok] so a caller can skip what depends on it.
func _check(ok: bool, what: String, detail := "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(_failure_prefix() + (what if detail == "" else "%s — %s" % [what, detail]))
		print("  FAIL  %s%s%s" % [_failure_prefix(), what, "" if detail == "" else " — " + detail])
	return ok


## Text put before a failed check's name (a subclass returns the course or map under test).
func _failure_prefix() -> String:
	return ""


## Prints the totals and failures, then quits: 1 on a failure or when [param expected] (if not -1) checks did not all run.
func _report(expected := -1) -> void:
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if expected >= 0 and _passed + _failed != expected:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, expected])
		_broken = true
	get_tree().quit(1 if _failed > 0 or _broken else 0)


## [method _report] for a suite that counts sections: also fails unless [param entered] sections all finished and equal [param sections].
func _report_sections(entered: int, finished: int, sections: int, checks := -1) -> void:
	print("")
	print("%d sections entered, %d finished" % [entered, finished])
	if entered != finished or entered != sections:
		print("ERROR: %d of %d sections finished, %d expected." % [finished, entered, sections])
		_broken = true
	_report(checks)
