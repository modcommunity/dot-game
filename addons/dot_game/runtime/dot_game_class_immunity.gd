class_name DotGameClassImmunity
extends RefCounted

## Per-class damage immunity for a game with dot-combat and dot-player-class, both loaded by path
## and named nowhere. A game calls [method apply] where it applies a class to a spawned player.
##
## [codeblock]
## DotGameClassImmunity.apply(combat, class_def, player_id)   # at every spawn; null def clears
## [/codeblock]

const IMMUNITY_SCRIPT := "res://addons/dot_combat/resolve/dot_damage_immunity.gd"
const APPLY_SCRIPT := "res://addons/dot_player_class/bridge/dot_player_class_apply.gd"


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
	if not (script is GDScript):
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
