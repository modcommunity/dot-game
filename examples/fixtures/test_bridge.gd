extends Node

## The bridge between a game and its netcode, reduced to the interface dot-game uses.
##
## Duck-typed by [DotGameNetcode] and [DotGameModule] on purpose: this is the game's own
## class in a real game, and this addon must not name it.

var game: Object = null
var net: DotNetManager = null

## What the module hands a services layer as its `link`.
var link: Object = null

## Set by the module when a services layer can relay voice.
var voice_relay_fn: Callable = Callable()

var attached: bool = false
var link_opened: bool = false
var ticks: Array[int] = []
var added: Array[int] = []
var removed: Array[int] = []

## Set by a suite to make `attach` refuse, which is the path that has to unwind.
var refuse_attach: bool = false


func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	if refuse_attach:
		return DotResult.fail(DotError.CODE_STATE, "refusing on purpose")

	game = p_game
	net = p_net
	attached = true
	return DotResult.success(null)


func open_link(_server: DotServer) -> void:
	link_opened = true
	link = self


func server_tick(tick: int) -> void:
	ticks.append(tick)


func add_player(peer_id: int, userid: int, _name: String) -> DotResult:
	added.append(userid)
	link = link if link != null else self
	return DotResult.success(peer_id)


func remove_peer(peer_id: int) -> void:
	removed.append(peer_id)
