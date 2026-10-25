extends Object

## The relevance settings as server cvars: `net_interest_radius`, `net_far_every`, `net_far_distance`. 0 on each means the game's own value; the operator file (the same names in server.yml) is the starting value.

const CHANNEL := "game.relevance"

## cvar name -> [DotNetInterestDistance] property.
const CVARS := {
	"net_interest_radius": "radius",
	"net_far_every": "far_every",
	"net_far_distance": "far_distance",
}

const SEED_KEYS := {"net_interest_radius": "interest_radius", "net_far_every": "far_every", "net_far_distance": "far_distance"}
const META_BOUND := &"relevance_bound_to"
const META_UNSEEDED := &"relevance_unseeded"

## cvar name -> profile type, for the workbench set.
const TYPES := {"net_interest_radius": "float", "net_far_every": "int", "net_far_distance": "float"}


## Registers the three cvars on [param console] (once) and follows them into [param net]'s default interest strategy; a game's own strategy is left alone. [param ceiling] seeds the defaults. Value: whether it bound.
static func bind(console: DotConsole, net: Object, ceiling: Dictionary = {}) -> bool:
	if console == null or net == null:
		return false
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
		"net_interest_radius":
			return "Metres: an entity farther than this from a player is not sent to them (the smaller of this and the game's wins). 0 keeps the game's. Applies at once."
		"net_far_every":
			return "An entity past net_far_distance goes out in one snapshot of this many. 0 keeps the game's, 1 is off."
	return "Metres past which an entity counts as far for net_far_every. 0 keeps the game's."
