extends Node

## The smallest thing that counts as a game object.
##
## A game registers itself in [DotRegistry] under a name its module knows, because
## there are no autoloads in this family: a process running a server and a client has
## two of everything, and a global would be one.

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
