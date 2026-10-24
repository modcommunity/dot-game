class_name DotGameNoblock
extends RefCounted

## Teammates pass through each other, enemies stop: dot-team's block rules wired once for every
## game. dot-team is loaded by path (not every game links it), so this names none of its classes.
##
## Server: [DotGameModule] builds one when the game has a `body_rules` (dot-player-controller's
## `DotPlayerBodyRules`), feeds its `pair_fn`, binds `mp_teamblock` & co (REPLICATED) and `!block` /
## `!noblock`. Client: `DotGameClient.add_noblock(rules)`. Config reaches cfg/ and the workbench as
## the `noblock` kind, over dot-team's `DotTeamBlockConfig`.

const CHANNEL := "game.noblock"
const RULES_SCRIPT := "res://addons/dot_team/core/dot_team_block_rules.gd"
const CONFIG_SCRIPT := "res://addons/dot_team/core/dot_team_block_config.gd"
const COMMANDS_SCRIPT := "res://addons/dot_team/runtime/dot_team_block_commands.gd"
const PROFILE_KIND := "noblock"
const CVAR_FIELDS := {
	"team_block": "mp_teamblock", "enemy_block": "mp_enemyblock", "command_mode": "mp_blockcmd",
	"command_relations": "mp_blockcmd_relations", "scope": "mp_blockscope",
}

## A `DotTeamBlockRules`.
var rules: Object = null
var binder: DotGameConfigBinder = null
var commands: Object = null
var _cvars: Dictionary = {}


static func available() -> bool:
	return ResourceLoader.exists(RULES_SCRIPT) and ResourceLoader.exists(CONFIG_SCRIPT)


## Builds the rules and runs the cfg layers over their config. Fails loudly (and, strict, refuses
## the boot) on a bad value or an unknown key; fails with CODE_UNSUPPORTED when dot-team is absent.
## [param roots] and [param strict] are for tests. [param side_fn] is `(player id) -> side id` ("" or null for none).
static func create(
	game_id: String, side_fn: Callable, roots := PackedStringArray(), strict := DotGameConfigBinder.default_strict()
) -> DotResult:
	if not available():
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "dot-team is not in this build.")
	var nb := DotGameNoblock.new()
	nb.rules = (load(RULES_SCRIPT) as GDScript).new()
	nb.rules.set(&"side_fn", side_fn)
	nb.binder = DotGameConfigBinder.create(nb.rules.get(&"config") as DotConfig, game_id, "mp")
	nb.binder.profile_kind = PROFILE_KIND
	nb.binder.profile_id = PROFILE_KIND
	nb.binder.strict = strict
	if not roots.is_empty():
		nb.binder.roots = roots
	var loaded := nb.binder.load_layers()
	if not loaded.ok:
		return loaded.wrap("noblock configuration")
	return DotResult.success(nb)


## Makes `pair_fn` of [param body_rules] answer from these rules.
func feed(body_rules: Object) -> void:
	body_rules.set(&"pair_fn", Callable(rules, &"blocks"))


## Server: the cvars, the workbench kind (when [param runtime] is given) and the chat commands.
## [param add_cvar] and [param host] are the module's `add_cvar` and the module itself.
func bind(add_cvar: Callable, host: Object, runtime: Object = null) -> DotResult:
	var flags := DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	for cv: Variant in rules.call(&"bind_cvars", add_cvar, flags, DotConVar.FLAG_REPLICATED):
		_cvars[(cv as DotConVar).name] = cv
	for field: String in CVAR_FIELDS:
		if not _cvars.has(CVAR_FIELDS[field]):
			return DotResult.fail(DotError.CODE_STATE, "cvar %s was not bound" % CVAR_FIELDS[field])
	binder.field_changed.connect(_on_field)
	if runtime != null:
		binder.attach(runtime as DotProfileRuntime)
	if ResourceLoader.exists(COMMANDS_SCRIPT):
		commands = (load(COMMANDS_SCRIPT) as GDScript).new(rules)
		var res: Variant = commands.call(&"install", host)
		if res is DotResult and not (res as DotResult).ok:
			return (res as DotResult).wrap("!block and !noblock")
	return DotResult.success(self)


## Client: follows the server's replicated values on [param source] (the game link).
func follow(source: Object) -> bool:
	return bool(rules.call(&"follow_cvars", source))


func _on_field(key: String, _value: Variant, source: String) -> void:
	if source == "cvar" or not CVAR_FIELDS.has(key):
		return
	var cv: DotConVar = _cvars.get(CVAR_FIELDS[key])
	if cv != null:
		var held: Variant = (rules.get(&"config") as Object).get(key)
		cv.force_set(("1" if held else "0") if held is bool else str(held))
