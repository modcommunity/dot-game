extends "test_chat_box.gd"

## A chat box with a voice manager, as DotGameChatClient has one.

var voice: Node = null
var voice_position_fn: Callable = Callable()


func _ready() -> void:
	voice = load("res://examples/fixtures/test_voice_state.gd").new()
	add_child(voice)
