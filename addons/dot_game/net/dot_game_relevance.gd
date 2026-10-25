extends Object

## The relevance settings as server cvars: `net_interest_radius`, `net_far_every`, `net_far_distance`. 0 on each means the game's own value; the operator file (the same names in server.yml) is the starting value.

const CHANNEL := "game.relevance"

## cvar name -> [DotNetInterestDistance] property.
const CVARS := {
	"net_interest_radius": "radius",
	"net_far_every": "far_every",
	"net_far_distance": "far_distance",
}

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
	var seed_keys := {"net_interest_radius": "interest_radius", "net_far_every": "far_every", "net_far_distance": "far_distance"}
	for name: String in CVARS:
		var cv := console.find_cvar(name)
		if cv == null:
			var start: Variant = ceiling.get(seed_keys[name], 0)
			cv = console.cvar(name, str(start), _help(name), DotConVar.FLAG_ARCHIVE)
			if name == "net_far_every":
				cv.with_range(0, 16)
			else:
				cv.with_range(0, 100000)
		cv.changed.connect(func(_old: String, value: String) -> void:
			if is_instance_valid(interest):
				interest.set(CVARS[name], effective(name, game[name], value.to_float())))
		interest.set(CVARS[name], effective(name, game[name], cv.get_float()))
	return true


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
