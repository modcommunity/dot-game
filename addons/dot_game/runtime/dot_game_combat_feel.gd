class_name DotGameCombatFeel
extends RefCounted

## Movement-dependent spread, recoil patterns and the spread crosshair for a game that opts in.
## dot-weapon and dot-ui are loaded by path and named nowhere: a build without them gets inert no-ops.
##
## [codeblock]
## var feel := DotGameCombatFeel.new(true)       # both sides; false keeps the rules off until sv_*_enabled
## feel.attach(player.arsenal)                   # every arsenal, both sides
## feel.track_tunables(player.controller.tunables)  # sprint and stamina, every player's tunables
## feel.bind_cvars(add_cvar)                     # server module
## client.add_combat_feel(feel, crosshair, func(): return player.arsenal)   # client
## [/codeblock]

const SPREAD_SCRIPT := "res://addons/dot_weapon/math/dot_weapon_spread_rules.gd"
const RECOIL_SCRIPT := "res://addons/dot_weapon/math/dot_weapon_recoil_rules.gd"
const BALLISTICS_SCRIPT := "res://addons/dot_weapon/math/dot_weapon_ballistics_rules.gd"
const SPRINT_SCRIPT := "res://addons/dot_player_controller/fp/core/dot_fps_sprint_rules.gd"
const CVAR_FLAGS := DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED

## DotWeaponSpreadRules, or null without dot-weapon.
var spread: RefCounted = null
## DotWeaponRecoilRules, or null without dot-weapon.
var recoil: RefCounted = null
## DotWeaponBallisticsRules (`sv_ballistics*`, always off until the cvar is set), or null without dot-weapon.
var ballistics: RefCounted = null
## DotFpsSprintRules (sv_sprint*, sv_stamina*), or null without dot-player-controller API 11 or when built with [code]sprint = false[/code].
var sprint: RefCounted = null
## DotCrosshairCvars (cl_crosshair_*), or null without dot-ui API 10.
var crosshair_cvars: RefCounted = null


var _tunables: Array = []


## [param with_sprint] false for a game with no sprint (its dash, say), so no sv_sprint* cvars appear.
func _init(on: bool = false, with_sprint: bool = true) -> void:
	spread = _make(SPREAD_SCRIPT, on)
	recoil = _make(RECOIL_SCRIPT, on)
	ballistics = _make(BALLISTICS_SCRIPT, false)
	if with_sprint:
		sprint = _make(SPRINT_SCRIPT, true)
		if sprint != null and sprint.has_signal(&"changed"):
			sprint.connect(&"changed", _push_sprint)
	if DotAddonApi.build_level("dot_ui") >= 10:
		var cvars: Variant = load("res://addons/dot_ui/hud/dot_crosshair_cvars.gd")
		if cvars is GDScript:
			crosshair_cvars = (cvars as GDScript).new() as RefCounted


static func _make(path: String, on: bool) -> RefCounted:
	if not ResourceLoader.exists(path):
		return null
	var script: Variant = load(path)
	if not (script is GDScript):
		return null
	var rules := (script as GDScript).new() as RefCounted
	if rules != null and path != SPRINT_SCRIPT:
		rules.set(&"enabled", on)
	return rules


## Hands both rule sets to [param arsenal]; call for every arsenal, server and client.
func attach(arsenal: Object) -> void:
	if arsenal == null:
		return
	if spread != null:
		arsenal.set(&"spread_rules", spread)
	if recoil != null:
		arsenal.set(&"recoil_rules", recoil)
	if ballistics != null:
		arsenal.set(&"ballistics_rules", ballistics)


## Takes the sprint and stamina numbers of a game's config tunables as the defaults (before [method bind_cvars]).
func sprint_defaults(source: Object) -> void:
	if sprint != null and source != null:
		var _applied: Variant = sprint.call(&"apply_from", source)


## Keeps [param tunables] (a player's DotFpsTunables) on the sprint rules now and on every later change, on both sides.
func track_tunables(tunables: Object) -> void:
	if tunables == null:
		return
	_tunables = _tunables.filter(func(t: Variant) -> bool: return is_instance_valid(t))
	if not _tunables.has(tunables):
		_tunables.append(tunables)
	if sprint != null:
		var _applied: Variant = sprint.call(&"apply_to", tunables)


func _push_sprint() -> void:
	for t: Variant in _tunables:
		if is_instance_valid(t):
			var _applied: Variant = sprint.call(&"apply_to", t)


## Server: registers sv_spread_*, sv_recoil_* and sv_sprint*/sv_stamina* (replicated) through [param add_cvar].
func bind_cvars(add_cvar: Callable, flags: int = CVAR_FLAGS) -> void:
	for rules: RefCounted in [spread, recoil, ballistics, sprint]:
		if rules != null:
			var _made: Variant = rules.call(&"bind_cvars", add_cvar, flags)


## Client: follows the server's values through [param link].
func follow_cvars(link: Object) -> void:
	for rules: RefCounted in [spread, recoil, ballistics, sprint]:
		if rules != null:
			var _followed: Variant = rules.call(&"follow_cvars", link)


## Registers cl_crosshair_* on a console's local source (or on a console, which has it among its sources); [param crosshair] is what they restyle.
func bind_console(console: Object, crosshair: Control = null) -> bool:
	if crosshair_cvars == null or console == null:
		return false
	if crosshair != null:
		crosshair_cvars.set(&"target", crosshair)
	if console.has_method(&"add_var"):
		return bool(crosshair_cvars.call(&"bind_console", console))
	if not console.has_method(&"sources"):
		return false
	for source: Variant in console.call(&"sources"):
		if source is Object and (source as Object).has_method(&"add_var"):
			return bool(crosshair_cvars.call(&"bind_console", source))
	return false


## Opens [param crosshair] to the cone of [param arsenal]'s weapon; no-op when the rules are off.
func drive(crosshair: Control, arsenal: Object, fov: float = 75.0) -> void:
	if crosshair == null or arsenal == null or spread == null or not bool(spread.get(&"enabled")):
		return
	if not crosshair.has_method(&"set_spread"):
		return
	crosshair.set(&"fov_degrees", clampf(fov, 10.0, 170.0))
	if arsenal.has_method(&"crosshair_scale"):
		crosshair.set(&"gap_scale", clampf(float(arsenal.call(&"crosshair_scale")), 0.1, 4.0))
	crosshair.call(&"set_spread", float(arsenal.call(&"spread_now")))
