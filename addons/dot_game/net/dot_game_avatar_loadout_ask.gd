class_name DotGameAvatarLoadoutAsk
extends DotNetMessage

## A client asking the server for every player's loadout, sent once its handler is attached: the
## loadouts told at its join land before a game that wires avatar actions late is listening.
## Client to server only; the server answers at most once per [constant DotGameAvatarLoadouts.ASK_MIN_SEC].

const NAME := &"game.avatar_loadout_ask"


func _type_name() -> StringName:
	return NAME


func _write(_w: DotNetWriter) -> void:
	pass


func _read(_r: DotNetReader) -> void:
	pass
