@tool
extends EditorPlugin

## Editor entry point for dot-game. Registers inspector types only.
##
## No autoloads: a process running two servers, or a server and a client, has two modules.

const _TYPES := [
	[
		"DotGameModule",
		"Node",
		"res://addons/dot_game/core/dot_game_module.gd",
	],
]


func _enter_tree() -> void:
	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), null)


func _exit_tree() -> void:
	for entry in _TYPES:
		remove_custom_type(entry[0])
