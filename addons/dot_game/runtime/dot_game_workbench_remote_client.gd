class_name DotGameWorkbenchRemoteClient
extends RefCounted

## The client half of the remote workbench: learns from the server whether this player may edit, and forwards edits.
##
## It only says what to draw. The server re-checks every request, so a client that lies about [member allowed] gets a refusal logged against its uid and nothing else.

const CHANNEL := "game.workbench"
## The actor the client's own api edits as; honoured only while [member allowed].
const ACTOR := "workbench-remote-client"

## The server says this player holds a workbench flag.
signal access_changed(allowed: bool)
## The server answered request [param seq]: [param reply] is {ok, value} or {ok: false, error: {code, message}}.
signal replied(seq: int, reply: Dictionary)
## The server refused a request; the local panel's optimistic edit is out of date.
signal refused(seq: int, message: String)

var allowed: bool = false
var flags := PackedStringArray()

var _net: DotNetManager = null
var _seq := 0


## Registers the message and starts listening. Call before the schema seals, on the client's manager.
static func attach(net: DotNetManager) -> DotGameWorkbenchRemoteClient:
	var made := DotGameWorkbenchMessage.register(net)
	if not made.ok:
		return null
	var c := DotGameWorkbenchRemoteClient.new()
	c._net = net
	var _on := net.messages.on(DotGameWorkbenchMessage.NAME, c._on_message)
	return c


## Asks the server where this player stands; call once connected.
func ask() -> void:
	var m := DotGameWorkbenchMessage.new()
	m.kind = DotGameWorkbenchMessage.KIND_ASK
	_send(m)


## Whether the local actor [param actor] may do [param flag] on this client's api: only [constant ACTOR], only while allowed.
func permit(actor: Variant, flag: String) -> bool:
	return actor is String and actor == ACTOR and allowed and flags.has(flag)


## Sends [param req] to the server. Value: its seq.
func request(req: Dictionary) -> int:
	_seq += 1
	var m := DotGameWorkbenchMessage.new()
	m.kind = DotGameWorkbenchMessage.KIND_REQUEST
	m.seq = _seq
	m.text = JSON.stringify(req)
	_send(m)
	return _seq


## Applies a decoded frame; also the entry point of a suite.
func handle_message(m: DotGameWorkbenchMessage) -> void:
	match m.kind:
		DotGameWorkbenchMessage.KIND_ACCESS:
			var was := allowed
			allowed = m.allowed
			flags = PackedStringArray(m.flags.split(",", false)) if allowed else PackedStringArray()
			if was != allowed:
				access_changed.emit(allowed)
		DotGameWorkbenchMessage.KIND_REPLY:
			var json := JSON.new()
			var parsed: Variant = json.data if json.parse(m.text) == OK else null
			if not (parsed is Dictionary):
				return
			replied.emit(m.seq, parsed)
			if not bool((parsed as Dictionary).get("ok", false)):
				refused.emit(m.seq, str(((parsed as Dictionary).get("error", {}) as Dictionary).get("message", "refused")))


func _on_message(message: DotNetMessage) -> void:
	var m := message as DotGameWorkbenchMessage
	if m != null:
		handle_message(m)


func _send(m: DotGameWorkbenchMessage) -> void:
	if _net == null:
		return
	var sent := _net.send(m)
	if not sent.ok:
		DotLog.debug(CHANNEL, "workbench frame not sent", {"why": sent.error.message})
