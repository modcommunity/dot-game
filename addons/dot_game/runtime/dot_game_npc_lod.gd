class_name DotGameNpcLod
extends RefCounted

## The NPC half of a server's cost as cvars, from one call: perception on worker threads (`sv_threads_npc`)
## and the level-of-detail dials of dot-npc-ai and dot-npc. All off until an operator turns them; names
## neither addon, so without them it parses and attaching is a no-op.

const CHANNEL := "game.npc_lod"
const SCHEDULER_SCRIPT := "res://addons/dot_npc_ai/runtime/dot_npc_ai_scheduler.gd"
const CONFIG_SCRIPT := "res://addons/dot_npc_ai/core/dot_npc_ai_scheduler_config.gd"

## cvar -> [default, min, max, scheduler config field ("" = not one), help]
const CVARS := {
	"npc_lod": [0, 0, 1, "enabled", "Think less often for NPCs far from every player (dot-npc-ai's scheduler). 0 thinks every tick."],
	"npc_lod_full": [30.0, 0, 10000, "full_range", "Metres: an NPC this close to a player thinks every tick."],
	"npc_lod_mid": [60.0, 0, 10000, "mid_range", "Metres: within this an NPC thinks every npc_lod_interval1 ticks."],
	"npc_lod_far": [120.0, 0, 10000, "far_range", "Metres: within this every npc_lod_interval2 ticks; beyond it every npc_lod_interval3."],
	"npc_lod_interval1": [3, 1, 1000, "tier1_interval", "Ticks between thinks at the middle tier."],
	"npc_lod_interval2": [10, 1, 1000, "tier2_interval", "Ticks between thinks at the far tier."],
	"npc_lod_interval3": [30, 0, 10000, "tier3_interval", "Ticks between thinks beyond npc_lod_far; 0 never."],
	"npc_lod_engaged": [1, 0, 3, "engaged_max_tier", "An NPC with a target is never calmer than this tier (0 = every tick)."],
	"npc_lod_budget_ms": [100.0, 0.1, 100, "budget_ms", "Most milliseconds all NPC thinks may take in a tick; 100 is no limit."],
	"npc_sense_quiet": [1, 1, 16, "", "An NPC that found nobody in reach senses this many times less often (1 = off)."],
}

## Profile types, for the workbench set.
const TYPES := {
	"npc_lod": "bool", "npc_lod_full": "float", "npc_lod_mid": "float", "npc_lod_far": "float",
	"npc_lod_interval1": "int", "npc_lod_interval2": "int", "npc_lod_interval3": "int",
	"npc_lod_engaged": "int", "npc_lod_budget_ms": "float", "npc_sense_quiet": "int",
}

var spawner: Object = null
var scheduler: Node = null
var console: DotConsole = null
var server_config: Object = null

var _host: Node = null
var _players: Callable = Callable()
var _applied := {}


## Registers the cvars on [param console] (once).
static func ensure_cvars(p_console: DotConsole) -> void:
	for name: String in CVARS:
		if p_console.find_cvar(name) != null:
			continue
		var spec: Array = CVARS[name]
		var cv := p_console.cvar(name, str(spec[0]), String(spec[4]), DotConVar.FLAG_ARCHIVE)
		cv.with_range(float(spec[1]), float(spec[2]))


## Wires [param p_spawner] (a DotNpcSpawner, duck-typed) to the cvars. The scheduler is built the first time
## `npc_lod` is 1, so a server that never turns it on pays nothing. [param p_players] returns the positions the
## tiers measure from; null takes the spawner's candidates.
static func attach(p_host: Node, p_console: DotConsole, p_spawner: Object, p_server_config: Object = null,
		p_players: Callable = Callable()) -> DotGameNpcLod:
	if p_spawner == null or p_console == null:
		return null
	ensure_cvars(p_console)
	var lod := DotGameNpcLod.new()
	lod._host = p_host
	lod.console = p_console
	lod.spawner = p_spawner
	lod.server_config = p_server_config
	lod._players = p_players
	lod.follow()
	return lod


## Applies the live cvars and advances the scheduler by [param delta]; call once per server tick, before the NPCs are ticked (the scheduler's own frame hook would run at the engine's rate, not the server's).
func follow(delta: float = 0.0) -> void:
	if spawner == null or not is_instance_valid(spawner):
		return
	if server_config != null and server_config.has_method(&"npc_workers"):
		spawner.set(&"sense_workers", int(server_config.call(&"npc_workers")))
	var limits: Object = spawner.get(&"limits")
	if limits != null:
		limits.set(&"sense_quiet_mult", console.get_int("npc_sense_quiet", 1))
	if scheduler == null:
		if console.get_int("npc_lod", 0) == 0 or not _build_scheduler():
			return
	var cfg: Object = scheduler.get(&"config")
	for name: String in CVARS:
		var field := String(CVARS[name][3])
		if field.is_empty():
			continue
		var value: Variant = console.get_float(name, 0.0)
		value = value != 0.0 if TYPES[name] == "bool" else (int(value) if TYPES[name] == "int" else value)
		if _applied.get(name) != value:
			_applied[name] = value
			cfg.set(field, value)
	if delta > 0.0 and console.get_int("npc_lod", 0) != 0:
		scheduler.call(&"advance", delta)


## Drops the scheduler this built (the spawner it served is gone).
func release() -> void:
	if scheduler != null and is_instance_valid(scheduler):
		scheduler.queue_free()
	scheduler = null


## One line per tier for the status page: thinks asked and granted.
func describe() -> Dictionary:
	if scheduler == null or not scheduler.has_method(&"describe"):
		return {"enabled": false}
	return scheduler.call(&"describe")


func _build_scheduler() -> bool:
	if not ResourceLoader.exists(SCHEDULER_SCRIPT) or not ResourceLoader.exists(CONFIG_SCRIPT) or _host == null:
		return false
	var made: Node = (load(SCHEDULER_SCRIPT) as GDScript).new()
	made.name = "NpcLod"
	made.set(&"auto_advance", false)
	made.call(&"apply_config", (load(CONFIG_SCRIPT) as GDScript).new())
	made.set(&"players_source", _players if _players.is_valid() else Callable(self, "_spawner_positions"))
	_host.add_child(made)
	made.call(&"register_service")
	scheduler = made
	return true


func _spawner_positions() -> Array:
	return spawner.call(&"candidate_positions") if spawner != null and spawner.has_method(&"candidate_positions") else []
