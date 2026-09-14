@tool
extends EditorPlugin

## Editor entry point for dot-game. Registers inspector types only.
##
## No autoloads. A module belongs to a server, and a process running two servers -- or
## a server and a client -- has two of them. That is the family rule and it is also the
## reason this addon exists as a base class rather than as a singleton that games call.

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
