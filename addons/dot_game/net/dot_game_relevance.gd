extends Object

## The relevance settings as server cvars: `net_interest_radius`, `net_far_every`, `net_far_distance`. 0 on each means the game's own value; the operator file (the same names in server.yml) is the starting value.

## cvar name -> [DotNetInterestDistance] property.
const CVARS := {
	"net_interest_radius": "radius",
	"net_far_every": "far_every",
	"net_far_distance": "far_distance",
}

const SEED_KEYS := {"net_interest_radius": "interest_radius", "net_far_every": "far_every", "net_far_distance": "far_distance"}
const META_BOUND := &"relevance_bound_to"
const META_UNSEEDED := &"relevance_unseeded"

## On/off cvars for dot-net's snapshot cost cuts, seeded from the game's own value (dot-net's default is on): cvar -> property of the manager's config or default interest.
const TOGGLES := {"net_skip_idle": "skip_idle_snapshots", "net_visibility": "visibility_enabled"}

## cvar name -> profile type, for the workbench set.
const TYPES := {"net_interest_radius": "float", "net_far_every": "int", "net_far_distance": "float"}


## Registers the three cvars on [param console] (once) and follows them into [param net]'s default interest strategy; a game's own strategy is left alone. [param ceiling] seeds the defaults. Value: whether it bound.
static func bind(console: DotConsole, net: Object, ceiling: Dictionary = {}) -> bool:
	if console == null or net == null:
		return false
	bind_toggles(console, net)
	var interest: Object = net.get(&"interest")
	if interest == null or not interest is DotNetInterestDistance:
		return false
	var game := {}
	for name: String in CVARS:
		game[name] = interest.get(CVARS[name])
	ensure_cvars(console, ceiling)
	for name: String in CVARS:
		var cv := console.find_cvar(name)
		var seeded: Variant = ceiling.get(SEED_KEYS[name], 0)
		# A cvar the workbench made before the netcode existed carries no ceiling yet; seed it once.
		if cv.has_meta(META_UNSEEDED):
			cv.remove_meta(META_UNSEEDED)
			if float(seeded) > 0.0 and cv.get_float() <= 0.0:
				console.set_cvar(name, str(seeded))
		# One listener per (cvar, strategy): bind() runs again for a cvar that already exists.
		if cv.get_meta(META_BOUND, 0) != interest.get_instance_id():
			cv.set_meta(META_BOUND, interest.get_instance_id())
			cv.changed.connect(func(_old: String, value: String) -> void:
				if is_instance_valid(interest):
					interest.set(CVARS[name], effective(name, game[name], value.to_float())))
		interest.set(CVARS[name], effective(name, game[name], cv.get_float()))
	return true


## Registers `net_skip_idle` and `net_visibility` (once) and follows them into [param net]'s config and interest, live. A target without the property (an older dot-net, a game's own strategy) is skipped.
static func bind_toggles(console: DotConsole, net: Object) -> void:
	for name: String in TOGGLES:
		var prop: String = TOGGLES[name]
		var target: Object = net.get(&"config") if name == "net_skip_idle" else net.get(&"interest")
		if target == null or not prop in target:
			continue
		var cv := console.find_cvar(name)
		if cv == null:
			cv = console.cvar(name, "1" if bool(target.get(prop)) else "0", _help(name), DotConVar.FLAG_ARCHIVE)
			cv.with_range(0, 1)
		if cv.get_meta(META_BOUND, 0) != target.get_instance_id():
			cv.set_meta(META_BOUND, target.get_instance_id())
			cv.changed.connect(func(_old: String, value: String) -> void:
				if is_instance_valid(target):
					target.set(prop, value.to_float() >= 0.5))
		target.set(prop, cv.get_float() >= 0.5)


## Gives [param net]'s default interest the potentially visible set of [param world] (a dot-map DotMapBspMesh with a `vis` record), placed at the origin; null or a map without one clears it. [param bounds] limits the set (empty: none). Value: whether a set is in force.
static func attach_visibility(net: Object, world: Object, bounds: AABB = AABB()) -> bool:
	if net == null:
		return false
	var interest: Object = net.get(&"interest")
	if interest == null or not &"visibility" in interest:
		return false
	var vis: Resource = null
	if world != null and world.has_method(&"vis_bytes") and &"manifest" in world:
		vis = DotNetVisibility.from_dot_map_mesh(world, bounds)
	interest.set(&"visibility", vis)
	return vis != null


## Creates the three cvars on [param console] when missing, so a workbench that starts before the netcode still finds them. [param ceiling] seeds new ones.
static func ensure_cvars(console: DotConsole, ceiling: Dictionary = {}) -> void:
	for name: String in CVARS:
		if console.find_cvar(name) != null:
			continue
		var start: Variant = ceiling.get(SEED_KEYS[name], 0)
		var cv := console.cvar(name, str(start), _help(name), DotConVar.FLAG_ARCHIVE)
		if name == "net_far_every":
			cv.with_range(0, 16)
		else:
			cv.with_range(0, 100000)
		if ceiling.is_empty():
			cv.set_meta(META_UNSEEDED, true)


## The value to use for [param name] given the game's own and the cvar's. 0 = the game's; the radius is a ceiling (the smaller wins), the far pair replaces.
static func effective(name: String, game_value: Variant, cvar_value: float) -> Variant:
	if cvar_value <= 0.0:
		return game_value
	if name == "net_interest_radius":
		var g := float(game_value)
		return cvar_value if g <= 0.0 else minf(g, cvar_value)
	if name == "net_far_every":
		return int(cvar_value)
	return cvar_value


static func _help(name: String) -> String:
	match name:
		"net_skip_idle":
			return "1: a snapshot tick no player is due skips its preparation (same snapshots, cheaper); 0: prepare every tick. Applies at once."
		"net_visibility":
			return "1: an entity the map's visibility data says a player cannot see is not sent to them (maps with that data only); 0: distance only. Applies at once."
		"net_interest_radius":
			return "Metres: an entity farther than this from a player is not sent to them (the smaller of this and the game's wins). 0 keeps the game's. Applies at once."
		"net_far_every":
			return "An entity past net_far_distance goes out in one snapshot of this many. 0 keeps the game's, 1 is off."
	return "Metres past which an entity counts as far for net_far_every. 0 keeps the game's."
