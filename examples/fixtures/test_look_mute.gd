extends Node

## A stand-in for dot-voice's DotVoiceLookMute in the shape DotGameClient sets (the suite runs
## without dot-voice): properties, tap(), pick_by_angle(); the real one is in each game's suite.

var manager: Object = null
var separate_keys: bool = false
var gag_action: StringName = &"voice_gag"
var mute_action: StringName = &"voice_mute"
var target_fn: Callable = Callable()
var chat_mute_fn: Callable = Callable()


func tap(_now_ms: int, is_mute_key: bool = false) -> void:
	var target := int(target_fn.call()) if target_fn.is_valid() else 0
	if target <= 0:
		return
	if is_mute_key:
		manager.set_local_mute(target, true)
		if chat_mute_fn.is_valid():
			chat_mute_fn.call(target, true)
	else:
		manager.set_gag(target, true)


static func pick_by_angle(_eye: Transform3D, positions: Dictionary, _d: float = 0.0, _a: float = 0.0) -> int:
	return int(positions.keys()[0]) if not positions.is_empty() else 0
