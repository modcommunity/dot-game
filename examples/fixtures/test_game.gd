extends Node

## The smallest thing that counts as a game object.
##
## Registers itself in [DotRegistry] under a name its module knows; there are no autoloads, so a global would be shared by a server and a client.

const SERVICE := &"test_game"

var tick_rate: int = 60
var ticks: int = 0
var players: Dictionary = {}

## Handed [method DotGameModule.is_peer_loading] by the module, because it is declared.
var peer_loading_fn: Callable = Callable()

## Set by a test to turn the module's noblock wiring on.
var body_rules: Object = null


func _ready() -> void:
	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)
