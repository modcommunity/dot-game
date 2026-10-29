class_name DotGameHitFlinch
extends RefCounted

## What being hit does to a first-person view: a roll and shake of the camera and a wobble of the aim while sighted, instead of dropping the sights.
## dot-player-controller's DotFpsAimBreak and its sv_hit_* tunables are loaded by path; without them every call is a no-op.
## Wire it with [method DotGameClient.add_hit_flinch], then call [method DotGameClient.note_hit] where the game learns the local player was hurt.

const AIM_BREAK_SCRIPT := "res://addons/dot_player_controller/fp/core/dot_fps_aim_break.gd"

## Returns the active DotFpsSampler (duck-typed), or null.
var sampler_fn: Callable = Callable()
## Returns the view's Camera3D, or null.
var camera_fn: Callable = Callable()
## Returns true while the player holds the sights up. Unset means the wobble never applies.
var aim_fn: Callable = Callable()
## Returns the DotFpsTunables carrying the sv_hit_* values; unset uses the sampler's.
var tunables_fn: Callable = Callable()

var _aim_break: RefCounted = null
var _wobble_applied := Vector2.ZERO
var _last_base := Transform3D.IDENTITY
var _last_result := Transform3D.IDENTITY
var _have_result := false


func _init() -> void:
	if ResourceLoader.exists(AIM_BREAK_SCRIPT):
		var script: Variant = load(AIM_BREAK_SCRIPT)
		if script is GDScript:
			_aim_break = (script as GDScript).new() as RefCounted


## Whether dot-player-controller's flinch is present.
func available() -> bool:
	return _aim_break != null


## Records a hit of [param amount] damage on the local player; [param weapon_scale] is the held weapon's multiplier on the flinch.
func note_hit(amount: float = 0.0, weapon_scale: float = 1.0) -> void:
	if _aim_break == null:
		return
	var tunables: Variant = _tunables()
	if tunables != null:
		_aim_break.call(&"note_hit", _now(), tunables, amount, weapon_scale)


## True while the sights are refused (sv_unscope_hit), for a game that gates its aim on it.
func blocked() -> bool:
	return _aim_break != null and bool(_aim_break.call(&"blocked", _now()))


## Forgets any hit (respawn).
func clear() -> void:
	if _aim_break != null:
		_aim_break.call(&"clear")
	_wobble_applied = Vector2.ZERO


## Applies this frame's shake and wobble; the client calls it every frame.
func drive() -> void:
	if _aim_break == null:
		return
	var now := _now()
	_apply_wobble(now)
	_apply_shake(now)


func _apply_wobble(now: float) -> void:
	var sampler: Variant = sampler_fn.call() if sampler_fn.is_valid() else null
	if not (sampler is Object) or not (sampler as Object).has_method(&"look_at_angles"):
		_wobble_applied = Vector2.ZERO
		return
	var aiming: bool = aim_fn.is_valid() and bool(aim_fn.call())
	var target: Vector2 = _aim_break.call(&"wobble", now) if aiming else Vector2.ZERO
	var step := target - _wobble_applied
	_wobble_applied = target
	if step != Vector2.ZERO:
		var s := sampler as Object
		s.call(&"look_at_angles", float(s.get(&"yaw")) + step.x, float(s.get(&"pitch")) + step.y)


# Undoes last frame's shake when the camera still holds exactly what was written, so a game that sets the transform only now and then does not accumulate it.
func _apply_shake(now: float) -> void:
	var cam: Variant = camera_fn.call() if camera_fn.is_valid() else null
	if not (cam is Camera3D) or not (cam as Camera3D).is_inside_tree():
		_have_result = false
		return
	var camera := cam as Camera3D
	var base := camera.transform
	if _have_result and base.is_equal_approx(_last_result):
		base = _last_base
	var shake: Vector3 = _aim_break.call(&"shake", now)
	var result := base
	if shake != Vector3.ZERO:
		result = Transform3D(base.basis * Basis(Vector3.BACK, deg_to_rad(shake.x)), base.origin + base.basis * Vector3(0.0, shake.y, shake.z))
	camera.transform = result
	_last_base = base
	_last_result = result
	_have_result = true


func _tunables() -> Variant:
	if tunables_fn.is_valid():
		return tunables_fn.call()
	var sampler: Variant = sampler_fn.call() if sampler_fn.is_valid() else null
	return (sampler as Object).get(&"tunables") if sampler is Object else null


static func _now() -> float:
	return Time.get_ticks_msec() * 0.001
