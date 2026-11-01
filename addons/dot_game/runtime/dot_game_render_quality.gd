extends RefCounted

## Client render-cost cvars: `r_msaa`, `r_scale`, `r_shadow_atlas`, `r_shadow_distance`, `r_sun_shadow_size`, `r_sun_shadow_splits`. Each defaults to the project's own value on desktop and to the cheaper one on the web, where a frame is bounded by draw calls and fill rate. No class_name: the client preloads it.

const CHANNEL := "game.render_quality"
const NAMES: Array[StringName] = [&"r_msaa", &"r_scale", &"r_shadow_atlas", &"r_shadow_distance", &"r_sun_shadow_size", &"r_sun_shadow_splits"]
const MSAA := [0, 2, 4, 8]

## -1 leaves the project's value alone; the web gets a number from [method web_defaults].
static var values := {&"r_msaa": -1.0, &"r_scale": -1.0, &"r_shadow_atlas": -1.0, &"r_shadow_distance": -1.0, &"r_sun_shadow_size": -1.0, &"r_sun_shadow_splits": -1.0}


## What a browser draws unless told otherwise: no MSAA, a 2048 positional shadow atlas, full scale, sun shadows no further than 60 m, a 2048 sun shadow map drawn in at most 2 splits (each split is a full scene pass).
static func web_defaults() -> Dictionary:
	return {&"r_msaa": 0.0, &"r_scale": 1.0, &"r_shadow_atlas": 2048.0, &"r_shadow_distance": 60.0, &"r_sun_shadow_size": 2048.0, &"r_sun_shadow_splits": 2.0}


## Sets the web defaults for every variable still at -1; call once before the first frame.
static func init_defaults() -> void:
	if not DotPlatform.is_web():
		return
	var d := web_defaults()
	for n: StringName in NAMES:
		if float(values[n]) < 0.0:
			values[n] = d[n]


## Validates and stores [param v] for [param name]; a DotResult.
static func set_value(name: StringName, v: Variant) -> DotResult:
	var s := str(v)
	if not s.is_valid_float():
		return DotResult.fail(DotError.CODE_INVALID, "%s takes a number (-1 is the project's own)" % name)
	var f := s.to_float()
	if f < 0.0:
		values[name] = -1.0
	elif name == &"r_msaa" and not MSAA.has(int(f)):
		return DotResult.fail(DotError.CODE_INVALID, "r_msaa is 0, 2, 4 or 8")
	elif name == &"r_scale" and (f < 0.25 or f > 2.0):
		return DotResult.fail(DotError.CODE_INVALID, "r_scale is 0.25 to 2")
	elif name == &"r_shadow_atlas" and (f < 1024.0 or f > 16384.0):
		return DotResult.fail(DotError.CODE_INVALID, "r_shadow_atlas is a size from 1024 to 16384")
	elif name == &"r_sun_shadow_size" and (f < 512.0 or f > 16384.0):
		return DotResult.fail(DotError.CODE_INVALID, "r_sun_shadow_size is a size from 512 to 16384")
	elif name == &"r_sun_shadow_splits" and not [1, 2, 4].has(int(f)):
		return DotResult.fail(DotError.CODE_INVALID, "r_sun_shadow_splits is 1, 2 or 4")
	else:
		values[name] = f
	return DotResult.success(values[name])


## Pushes the stored values onto [param viewport] and every sun under [param root].
static func apply(viewport: Viewport, root: Node) -> void:
	if viewport == null:
		return
	var m := int(values[&"r_msaa"])
	if m >= 0:
		viewport.msaa_3d = {0: Viewport.MSAA_DISABLED, 2: Viewport.MSAA_2X, 4: Viewport.MSAA_4X, 8: Viewport.MSAA_8X}[m]
	if float(values[&"r_scale"]) > 0.0:
		viewport.scaling_3d_scale = float(values[&"r_scale"])
	if float(values[&"r_shadow_atlas"]) > 0.0:
		viewport.positional_shadow_atlas_size = int(values[&"r_shadow_atlas"])
	if float(values[&"r_sun_shadow_size"]) > 0.0:
		RenderingServer.directional_shadow_atlas_set_size(int(values[&"r_sun_shadow_size"]), true)
	if root != null and (float(values[&"r_shadow_distance"]) > 0.0 or float(values[&"r_sun_shadow_splits"]) > 0.0):
		for n in root.find_children("*", "DirectionalLight3D", true, false):
			cap_sun(n as DirectionalLight3D)
	DotLog.debug(CHANNEL, "render quality applied", {"values": values})


## Limits one sun's shadow distance to `r_shadow_distance` and its split count to `r_sun_shadow_splits` (never raises either).
static func cap_sun(sun: DirectionalLight3D) -> void:
	if not is_instance_valid(sun):
		return
	var dist := float(values[&"r_shadow_distance"])
	if dist > 0.0 and (sun.directional_shadow_max_distance == 0.0 or sun.directional_shadow_max_distance > dist):
		sun.directional_shadow_max_distance = dist
	var splits := int(values[&"r_sun_shadow_splits"])
	var have: int = {DirectionalLight3D.SHADOW_ORTHOGONAL: 1, DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS: 2}.get(sun.directional_shadow_mode, 4)
	if splits > 0 and have > splits:
		sun.directional_shadow_mode = {1: DirectionalLight3D.SHADOW_ORTHOGONAL, 2: DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS}[splits]


## Adds the variables to a client console source; [param reapply] runs after a change.
static func add_client_vars(local: Object, reapply: Callable) -> void:
	for n: StringName in NAMES:
		local.call(&"add_var", n, "Render cost: -1 is the project's value (web: the cheaper one). See dot-game's render quality.",
			func() -> Variant: return values[n],
			func(v: Variant) -> Variant:
				var res := set_value(n, v)
				if res.ok:
					reapply.call()
				return res)


## Applies `--r_msaa=2` style user arguments, and on the web the page's `?r_msaa=2` query.
static func apply_cmdline() -> void:
	if DotWeb.available():
		for n: StringName in NAMES:
			var q := DotWeb.query_param(n)
			if q != "":
				var _q := set_value(n, q)
	for a in OS.get_cmdline_user_args():
		for n: StringName in NAMES:
			if a.begins_with("--%s=" % n):
				var _r := set_value(n, a.get_slice("=", 1))
