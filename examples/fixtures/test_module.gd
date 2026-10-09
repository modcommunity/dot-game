extends DotGameModule

## A whole server game's wiring, in the thirty lines dot-game leaves you.
##
## This is the point of the addon stated as a file: everything that used to be two
## hundred lines of identical prose per game -- the netcode manager and its four
## load-bearing constants, the bridge, the seal, the identity layer, the platform
## module, the services layer and its link, the roster, the tick, and a teardown in the
## reverse order -- is in [DotGameModule]. What is left is what is actually this game's.
##
## Loaded by PATH, because [method DotModuleHost.load_module] constructs the module
## itself: that is the shape that lets an operator name one in a config file.

const TestGame := preload("test_game.gd")
const TestBridge := preload("test_bridge.gd")
const TestIdentity := preload("test_identity.gd")
const TestServices := preload("test_services.gd")
const TestClock := preload("test_clock.gd")

## Set by a suite before loading, to drive the paths that have to unwind.
static var refuse_game_load := false
static var refuse_attach := false
static var skip_identity := false
static var skip_services := false

## While true, [method _can_tick] says no — the lobby's "the world under me was freed".
static var hold_ticks := false

var game_loaded := 0
var game_unloaded := 0
var game_ticks: Array[int] = []

## What [method _game_hibernation] heard, in order.
var hibernation_heard: Array[bool] = []

## A clock under the module, as a vote wrapper would hold one.
var clock: Node = null


func _module_name() -> String:
	return "testgame"


func _game_service() -> StringName:
	return TestGame.SERVICE


func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = 60
	config.snapshot_rate = 20
	config.max_entities_per_snapshot = 32
	return config


func _make_bridge() -> Node:
	var bridge := TestBridge.new()
	bridge.refuse_attach = refuse_attach
	return bridge


func _make_identity() -> Node:
	return null if skip_identity else TestIdentity.new()


## Off, because dot-platform is not installed in this project and a missing module is
## reported rather than fatal -- which is worth asserting once, in the section that does
## it, rather than logging an error in every other section.
func _wants_platform_module() -> bool:
	return false


func _can_tick() -> bool:
	return not hold_ticks


func _make_services() -> Node:
	return null if skip_services else TestServices.new()


func _game_load() -> DotResult:
	game_loaded += 1

	if refuse_game_load:
		return DotResult.fail(DotError.CODE_STATE, "refusing on purpose")

	add_command("testgame_status", _cmd_status, "Show the game's state")

	# Two levels down, as every game's DotVoteDirector sits inside its vote wrapper.
	var wrapper := Node.new()
	wrapper.name = "Vote"
	add_child(wrapper)
	clock = TestClock.new()
	clock.name = "Clock"
	wrapper.add_child(clock)
	return DotResult.success(null)


## A column for the Tab board, so the suite can see the hook reach the server.
func _game_board_fields(session: Object) -> Dictionary:
	return {"kills": 3, "who": int(session.get("userid"))}


func _game_board_extra() -> Dictionary:
	return {"teams": [{"id": 1, "name": "Testers"}]}


func _game_unload() -> void:
	game_unloaded += 1


func _game_hibernation(hibernating: bool) -> void:
	hibernation_heard.append(hibernating)


func _game_tick(t: int, _delta: float) -> void:
	game_ticks.append(t)


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(describe_lines())
