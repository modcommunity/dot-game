class_name DotGameWorkbenchMessage
extends DotNetMessage

## One frame of the remote workbench: a client's ask, request, or the server's access notice and reply.

const NAME := &"game.workbench"
const KIND_ASK := 0
const KIND_REQUEST := 1
const KIND_REPLY := 2
const KIND_ACCESS := 3
## Wire cap on the JSON text; the server also enforces its own `max_bytes`.
const MAX_TEXT := 8192

var kind: int = KIND_ASK
## Echoed in the reply so a client can match it to its request.
var seq: int = 0
## ACCESS: whether the panel may be shown.
var allowed: bool = false
## ACCESS: the workbench flags the player holds, comma separated.
var flags: String = ""
## REQUEST: the JSON request; REPLY: the JSON reply (see [method DotWorkbenchApi.to_reply]).
var text: String = ""


func _type_name() -> StringName:
	return NAME


func _write(w: DotNetWriter) -> void:
	w.write_uint(kind, 8)
	w.write_varint(seq)
	w.write_bool(allowed)
	w.write_string(flags, 64)
	w.write_string(text, MAX_TEXT)


func _read(r: DotNetReader) -> void:
	kind = r.read_uint(8)
	seq = r.read_varint()
	allowed = r.read_bool()
	flags = r.read_string(64)
	text = r.read_string(MAX_TEXT)


func _validate() -> DotResult:
	if kind > KIND_ACCESS:
		return DotResult.fail(DotError.CODE_INVALID, "workbench frame kind out of range")
	return DotResult.success(true)


## Registers the type on [param net]'s manager, both ends, before the schema seals. Not required, so an old peer still connects.
static func register(net: DotNetManager) -> DotResult:
	if net.messages.type_names().has(String(NAME)):
		return DotResult.success(true)
	return net.messages.register(NAME, DotGameWorkbenchMessage, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.BOTH, false)
