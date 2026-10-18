extends Node

## A stand-in chat box in DotGameChatClient's shape: typing_changed and is_typing().

signal typing_changed(typing: bool)

var typing: bool = false


func is_typing() -> bool:
	return typing


func set_typing(on: bool) -> void:
	typing = on
	typing_changed.emit(on)
