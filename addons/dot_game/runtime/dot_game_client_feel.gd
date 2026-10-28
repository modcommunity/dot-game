class_name DotGameClientFeel
extends RefCounted

## The combat-feel driver of [DotGameClient]; the client keeps the state.


static func add(c: DotGameClient, feel: DotGameCombatFeel, crosshair: Control, arsenal_fn: Callable, camera_fn: Callable) -> void:
	c._feel = feel
	c._feel_crosshair = crosshair
	c._feel_arsenal_fn = arsenal_fn
	c._feel_camera_fn = camera_fn
	if c.link != null:
		feel.follow_cvars(c.link)
	if c.console != null:
		var _bound := feel.bind_console(c.console, crosshair)


static func drive(c: DotGameClient) -> void:
	if c._feel == null or not c._feel_arsenal_fn.is_valid():
		return
	if not c._feel_console_bound and c.console != null:
		c._feel_console_bound = c._feel.bind_console(c.console, c._feel_crosshair)
	var cam: Variant = c._feel_camera_fn.call() if c._feel_camera_fn.is_valid() else null
	var fov: float = float((cam as Camera3D).fov) if cam is Camera3D else 75.0
	c._feel.drive(c._feel_crosshair, c._feel_arsenal_fn.call() as Object, fov)
