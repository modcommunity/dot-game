class_name DotGameClassImmunity
extends RefCounted

## Per-class damage immunity for a game with dot-combat and dot-player-class, both loaded by path
## and named nowhere. Call [method apply] with (combat, class_def, player_id) at every spawn; a null def clears.

const CHANNEL := "game.class"
const IMMUNITY_SCRIPT := "res://addons/dot_combat/resolve/dot_damage_immunity.gd"
const APPLY_SCRIPT := "res://addons/dot_player_class/bridge/dot_player_class_apply.gd"

static var _warned_old := false


## Writes [param def]'s `immune_to` for [param entity] onto [param combat]'s resolver, creating the
## [code]DotDamageImmunity[/code] on first use. A null [param def] (or one with none) clears the
## entity, so a respawn as another class keeps nothing of the old one. Returns the kinds written.
static func apply(combat: Object, def: Object, entity: int) -> int:
	var immunity := ensure(combat)
	if immunity == null:
		return 0
	if def == null:
		immunity.call(&"clear", entity)
		return 0
	var script: Variant = load(APPLY_SCRIPT) if ResourceLoader.exists(APPLY_SCRIPT) else null
	return call_apply(script, def, immunity, entity)


## Calls [param script]'s static `to_immunity`, or returns 0 once logged when it has none: a
## dot-player-class older than v0.1.7 lacks it, and the call would be a script error every spawn.
static func call_apply(script: Variant, def: Object, immunity: Object, entity: int) -> int:
	if not (script is GDScript):
		return 0
	if not (script as GDScript).get_script_method_list().any(func(m: Dictionary) -> bool: return m.name == "to_immunity"):
		if not _warned_old:
			_warned_old = true
			DotLog.warn(CHANNEL, "dot-player-class has no to_immunity (older than v0.1.7); class immunity is off", {"script": (script as GDScript).resource_path})
		return 0
	return int((script as GDScript).call(&"to_immunity", def, immunity, entity))


## Forgets [param entity]'s immunities (it left, or died for good).
static func clear(combat: Object, entity: int) -> void:
	var immunity := ensure(combat, false)
	if immunity != null:
		immunity.call(&"clear", entity)


## The combat's resolver immunity, created when [param create] and absent; null without dot-combat.
static func ensure(combat: Object, create: bool = true) -> Object:
	if combat == null:
		return null
	var resolver: Variant = combat.get(&"resolver")
	if not (resolver is Object) or not (resolver as Object).has_method(&"resolve"):
		return null
	var held: Variant = (resolver as Object).get(&"immunity")
	if held is Object:
		return held as Object
	if not create or not ResourceLoader.exists(IMMUNITY_SCRIPT):
		return null
	var script: Variant = load(IMMUNITY_SCRIPT)
	if not (script is GDScript):
		return null
	var made: Object = (script as GDScript).new()
	(resolver as Object).set(&"immunity", made)
	return made
