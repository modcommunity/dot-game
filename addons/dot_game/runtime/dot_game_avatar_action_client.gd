class_name DotGameAvatarActionClient
extends Node

## The client half of avatar actions: a key press plays on the local figure at once and is sent
## to the server; what the server relays plays on that peer's figure, started at the right
## moment by its tick. Built by [method DotGameClient.add_avatar_actions].

const CHANNEL := "game.avatar_action"

var net: DotNetManager = null
var input: Object = null

## func(peer_id: int) -> Object with play_action(id: StringName, loop: bool, elapsed: float): the figure of that peer, or null.
var figure_fn: Callable = Callable()

## func() -> bool: true while a menu, a chat box or the like has the keyboard.
var blocked_fn: Callable = Callable()

var _online := false


## [param p_net] is null offline: the action plays locally and goes nowhere.
func attach(p_net: DotNetManager, p_input: Object, p_figure_fn: Callable) -> void:
	net = p_net
	input = p_input
	figure_fn = p_figure_fn
	input.connect(&"action_requested", _on_requested)
	if net != null:
		var on := net.messages.on(DotGameAvatarActionMessage.NAME, _on_message)
		_online = on.ok
		if not on.ok:
			DotLog.warn(CHANNEL, "type not registered before the seal; actions stay local",
				{"why": on.error.message})


func _process(_delta: float) -> void:
	if input != null and blocked_fn.is_valid():
		input.set(&"enabled", not bool(blocked_fn.call()))


func _on_requested(entry: Dictionary) -> void:
	var id := String(entry.get("id", ""))
	var loop := bool(entry.get("loop", false))
	_play(net.local_peer_id if net != null else 0, id, loop, 0.0)
	if not _online:
		return
	var request := DotGameAvatarActionMessage.new()
	request.id = id
	request.loop = loop
	var sent := net.send(request)
	if not sent.ok:
		DotLog.debug(CHANNEL, "request not sent", {"why": sent.error.message})


func _on_message(message: DotNetMessage) -> void:
	var m := message as DotGameAvatarActionMessage
	if m == null or m.actor == net.local_peer_id:
		return
	var late := maxi(0, net.clock.tick - m.start_tick)
	_play(m.actor, m.id, m.loop, float(late) / float(maxi(1, net.clock.tick_rate)))


func _play(peer_id: int, id: String, loop: bool, elapsed: float) -> void:
	var figure: Object = figure_fn.call(peer_id) if figure_fn.is_valid() else null
	if figure != null and is_instance_valid(figure) and figure.has_method(&"play_action"):
		figure.call(&"play_action", StringName(id), loop, elapsed)
