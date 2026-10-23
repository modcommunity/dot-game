extends Node

## A stand-in for DotVoiceManager's gag and mute state.

var gagged: Dictionary = {}
var local_mutes: Dictionary = {}


func set_gag(speaker: int, on: bool) -> void:
	gagged[speaker] = on


func set_local_mute(speaker: int, on: bool) -> void:
	local_mutes[speaker] = on
