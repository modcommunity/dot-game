class_name DotGameAvatarActionMessage
extends DotNetMessage

## An avatar action starting: a client asks (id, loop), the server checks and tells everyone
## (who, id, loop, the server tick it began on).

const NAME := &"game.avatar_action"

## The peer playing it; the server writes it, a client's request leaves it 0.
var actor: int = 0
var id: String = ""
var loop: bool = false
var start_tick: int = 0


func _type_name() -> StringName:
	return NAME


func _write(w: DotNetWriter) -> void:
	w.write_varint(actor)
	w.write_string(id, 32)
	w.write_bool(loop)
	w.write_uint(start_tick, 32)


func _read(r: DotNetReader) -> void:
	actor = r.read_varint()
	id = r.read_string(32)
	loop = r.read_bool()
	start_tick = r.read_uint(32)


func _validate() -> DotResult:
	if id == "" or id.length() > 32:
		return DotResult.fail(DotError.CODE_INVALID, "avatar action id out of range")
	return DotResult.success(true)


## Registers the type on [param net]'s manager: call on both ends, before the schema is sealed.
## Not required, so a peer without it still plays. Registers [DotGameAvatarLoadoutMessage] and
## [DotGameAvatarLoadoutAsk] too, so every game that already calls this hears other players' loadouts.
static func register(net: DotNetManager) -> DotResult:
	if not net.messages.type_names().has(String(DotGameAvatarLoadoutMessage.NAME)):
		var _l := net.messages.register(DotGameAvatarLoadoutMessage.NAME, DotGameAvatarLoadoutMessage,
			DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT, false)
	if not net.messages.type_names().has(String(DotGameAvatarLoadoutAsk.NAME)):
		var _a := net.messages.register(DotGameAvatarLoadoutAsk.NAME, DotGameAvatarLoadoutAsk,
			DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER, false)
	return net.messages.register(NAME, DotGameAvatarActionMessage, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.BOTH, false)
