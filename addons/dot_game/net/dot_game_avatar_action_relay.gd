class_name DotGameAvatarActionRelay
extends RefCounted

## The server half of avatar actions: checks a client's request and tells every peer.
## Refused when the id is not one the peer has equipped, when it asked less than
## [member min_interval_sec] ago, or when [member veto_fn] says no.

const CHANNEL := "game.avatar_action"

## The site's BUILTIN_AVATAR_ACTIONS ids: what anybody may play before equipping anything.
const STARTER_IDS: PackedStringArray = ["wave", "point", "thumbs_up", "nod", "shrug", "cheer", "dance",
	"clap", "bow", "sit", "salute", "arms_crossed", "hands_on_hips"]

const NET_META := &"dot_avatar_action_relay"

var min_interval_sec: float = 0.6

## func(peer_id: int) -> Variant: an Array of equipped ids, or null for the starter set.
var equipped_fn: Callable = Callable()

## func(peer_id: int, id: String) -> bool: true refuses the action.
var veto_fn: Callable = Callable()

## The server-read loadouts; built by [method serve], a child of the manager.
var loadouts: DotGameAvatarLoadouts = null

## Milliseconds; replaced by a suite.
var now_fn: Callable = Callable(Time, &"get_ticks_msec")

var _net: DotNetManager = null
var _last: Dictionary = {}


## Registers the type on [param net], answers requests and stores itself as [constant NET_META].
## [param game] may define `_avatar_actions_equipped(peer)` and `_avatar_action_veto(peer, id)`;
## a game not on [DotGameModule] passes its dot-server as [param server] and its [DotGameRoster] as [param roster].
static func serve(net: DotNetManager, game: Object = null, server: Object = null,
		roster: Object = null) -> DotResult:
	var made := DotGameAvatarActionMessage.register(net)
	if not made.ok:
		return made
	var relay := DotGameAvatarActionRelay.new()
	relay._net = net
	if game != null and game.has_method(&"_avatar_actions_equipped"):
		relay.equipped_fn = Callable(game, &"_avatar_actions_equipped")
	if game != null and game.has_method(&"_avatar_action_veto"):
		relay.veto_fn = Callable(game, &"_avatar_action_veto")
	var _on := net.messages.on(DotGameAvatarActionMessage.NAME, relay._on_message)
	var _ask := net.messages.on(DotGameAvatarLoadoutAsk.NAME, relay._on_ask)
	relay.loadouts = DotGameAvatarLoadouts.new()
	relay.loadouts.name = "AvatarLoadouts"
	relay.loadouts.net = net
	relay.loadouts.relay = relay
	relay.loadouts.server = server
	if roster != null and roster.has_method(&"follow"):
		roster.call(&"follow", relay.loadouts)
	net.add_child(relay.loadouts)
	net.set_meta(NET_META, relay)
	return DotResult.success(relay)


## The loadouts [method serve] built on [param net], or null. A server that is not on
## [DotGameModule] calls `add_peer(peer)` / `remove_peer(peer)` on it as players join and leave.
static func loadouts_of(net: DotNetManager) -> DotGameAvatarLoadouts:
	var relay: Variant = net.get_meta(NET_META, null) if net != null else null
	return (relay as DotGameAvatarActionRelay).loadouts if relay is DotGameAvatarActionRelay else null


## True when [param peer_id] may play [param id] now; records it as played.
func allow(peer_id: int, id: String) -> bool:
	var equipped: Variant = equipped_fn.call(peer_id) if equipped_fn.is_valid() else null
	if equipped == null and loadouts != null:
		equipped = loadouts.ids_for(peer_id)
	var ok: bool = equipped.has(id) if equipped is Array else STARTER_IDS.has(id)
	if not ok:
		DotLog.debug(CHANNEL, "not equipped", {"peer": peer_id, "id": id})
		return false
	var now: int = int(now_fn.call())
	if _last.has(peer_id) and now - int(_last[peer_id]) < int(min_interval_sec * 1000.0):
		DotLog.debug(CHANNEL, "too fast", {"peer": peer_id, "id": id})
		return false
	if veto_fn.is_valid() and bool(veto_fn.call(peer_id, id)):
		DotLog.debug(CHANNEL, "vetoed", {"peer": peer_id, "id": id})
		return false
	if _last.size() > 256:
		_last.clear()
	_last[peer_id] = now
	return true


func forget(peer_id: int) -> void:
	_last.erase(peer_id)


func _on_ask(message: DotNetMessage) -> void:
	if loadouts != null and message != null and message.sender_peer_id > 0:
		var _sent := loadouts.answer(message.sender_peer_id)


func _on_message(message: DotNetMessage) -> void:
	var request := message as DotGameAvatarActionMessage
	if request == null or request.sender_peer_id <= 0 or not allow(request.sender_peer_id, request.id):
		return
	var out := DotGameAvatarActionMessage.new()
	out.actor = request.sender_peer_id
	out.id = request.id
	var known: Dictionary = loadouts.entry_for(request.sender_peer_id, request.id) if loadouts != null else {}
	if not known.is_empty():
		out.loop = bool(known["loop"])
	elif DotGameAvatarLoadouts.STARTER_KINDS.has(request.id):
		out.loop = DotGameAvatarLoadouts.STARTER_LOOPS.has(request.id)
	else:
		out.loop = request.loop  # the game's own id (equipped_fn): the server has no definition
	out.start_tick = _net.clock.tick
	var sent := _net.send(out)
	if not sent.ok:
		DotLog.warn(CHANNEL, "could not tell peers", {"why": sent.error.message})
