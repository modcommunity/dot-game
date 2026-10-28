class_name DotGameTrailRelay
extends RefCounted

## The server half of player trails: runs a client's equip request through dot-trail's DotTrailEquip (access rule, cooldown) and tells every peer the id now worn. A refused request is answered with the id still worn, so the client's view reverts. The server's record is the only truth.

const CHANNEL := "game.trail"
const NET_META := &"dot_trail_relay"

## A dot-trail DotTrailEquip (duck-typed; dot-game does not depend on dot-trail).
var equip: Object
## func(peer_id: int) -> PackedStringArray: the groups the player is in (from the session or the backbone).
var groups_fn: Callable = Callable()
## func(peer_id: int) -> PackedStringArray: trail ids the backend says the player bought.
var entitlements_fn: Callable = Callable()

var _net: DotNetManager = null
var _peers: Dictionary = {}


## Registers the type on [param net], answers requests and stores itself as [constant NET_META]. [param roster] (a DotGameRoster) calls add_peer and remove_peer as players come and go.
static func serve(net: DotNetManager, p_equip: Object, p_groups_fn: Callable = Callable(),
		p_entitlements_fn: Callable = Callable(), roster: Object = null) -> DotResult:
	var made := DotGameTrailMessage.register(net)
	if not made.ok:
		return made
	var relay := DotGameTrailRelay.new()
	relay._net = net
	relay.equip = p_equip
	relay.groups_fn = p_groups_fn
	relay.entitlements_fn = p_entitlements_fn
	var _on := net.messages.on(DotGameTrailMessage.NAME, relay._on_message)
	if roster != null and roster.has_method(&"follow"):
		roster.call(&"follow", relay)
	net.set_meta(NET_META, relay)
	return DotResult.success(relay)


static func of(net: DotNetManager) -> DotGameTrailRelay:
	var relay: Variant = net.get_meta(NET_META, null) if net != null else null
	return relay as DotGameTrailRelay


## A player joined: tell them who wears what.
func add_peer(peer_id: int) -> void:
	_peers[peer_id] = true
	for other: int in _peers:
		var worn := String(equip.call(&"worn", other))
		if other != peer_id and not worn.is_empty():
			_send(other, worn, peer_id)


## A player left: forget their choice and tell everyone to drop the ribbon.
func remove_peer(peer_id: int) -> void:
	_peers.erase(peer_id)
	equip.call(&"forget", peer_id)
	_send(peer_id, "", 0)


## Re-checks a player's trail after their groups or entitlements changed; true when it was taken off.
func revalidate(peer_id: int) -> bool:
	var dropped: bool = equip.call(&"revalidate", peer_id, _groups(peer_id), _entitlements(peer_id))
	if dropped:
		_send(peer_id, "", 0)
	return dropped


func _on_message(message: DotNetMessage) -> void:
	var request := message as DotGameTrailMessage
	if request == null or request.sender_peer_id <= 0:
		return
	var peer := request.sender_peer_id
	var res: DotResult = equip.call(&"equip", peer, request.id, _groups(peer), _entitlements(peer))
	if res.ok:
		_send(peer, request.id, 0)
	else:
		DotLog.debug(CHANNEL, "equip refused", {"peer": peer, "id": request.id, "code": res.code()})
		_send(peer, String(equip.call(&"worn", peer)), peer)


func _groups(peer_id: int) -> PackedStringArray:
	return groups_fn.call(peer_id) if groups_fn.is_valid() else PackedStringArray()


func _entitlements(peer_id: int) -> PackedStringArray:
	return entitlements_fn.call(peer_id) if entitlements_fn.is_valid() else PackedStringArray()


func _send(actor: int, id: String, to_peer: int) -> void:
	if _net == null:
		return
	var m := DotGameTrailMessage.new()
	m.actor = actor
	m.id = id
	var sent := _net.send(m, to_peer)
	if not sent.ok:
		DotLog.debug(CHANNEL, "trail not sent", {"to": to_peer, "why": sent.error.message})
