extends Node
## Stands in for DotCloudClient: records the ensure_locked call and answers with a fixed report.

var calls: Array = []
var fail: bool = false
var gate: DotLoadGate = null
var held_during: bool = false


func ensure_locked(lock_path: String, opts: Dictionary = {}) -> DotResult:
	calls.append({"lock": lock_path, "opts": opts})
	held_during = gate != null and gate.is_holding(&"locked_content")
	await get_tree().process_frame
	if fail:
		return DotResult.fail(DotError.CODE_NETWORK, "nope")
	return DotResult.success({"mounted": ["me/pack@1.0.0"], "skipped": [], "failed": []})
