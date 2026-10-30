extends RefCounted

## A movement tunable set: one cvar, one member.

var gravity := 20.0


func cvar_specs() -> Array[Dictionary]:
	return [{"name": "sv_gravity", "value": gravity, "description": "Gravity"}]


func set_cvar(cvar_name: String, value: String) -> bool:
	if cvar_name != "sv_gravity":
		return false
	gravity = value.to_float()
	return true
