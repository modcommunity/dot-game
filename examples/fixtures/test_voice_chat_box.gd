extends "test_chat_box.gd"

## A chat box with a voice manager, as DotGameChatClient has one.

var voice: Node = null
var voice_position_fn: Callable = Callable()


func _ready() -> void:
	voice = load("res://examples/fixtures/test_voice_state.gd").new()
	add_child(voice)

## A block list in dot-chat's self-mute shape: a roster and set_muted.
var self_mute: Object = Mute.new()


class Mute extends RefCounted:
	var roster: Array[Dictionary] = []
	var you: int = 0
	var muted: Array = []
	func set_muted(who: Dictionary, on: bool) -> void:
		muted.append([who["name"], on])
