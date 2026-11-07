class_name DotGameRequest
extends DotNetMessage

## A client asking the server for something: reliable, rare, never trusted. Every game had written this file (a kind and a body, the same ~65 lines); the game now subclasses it and adds only its name and its kinds.
## One message type with a kind inside, so a new request is not a wire-id change on both ends. Nothing in a request is a fact: the server decides, and takes the sender from the transport, never from the body.
## A game overrides [method _type_name] (its wire name) and [method _kind_count] (how many kinds its enum has); [method _validate] uses the count and a suite asserts [method fits] with it.
## [b]Build it with [code]new(kind, body)[/code], and a subclass must not preload its own script[/b]: a [DotNetMessage] that preloads itself and is first loaded from a module a running [DotServer] loads leaks the script graph at exit on Godot 4.7.2 (mg-buses-from-hell 8ed866c). The registry decodes with a bare [code]new()[/code], so both arguments default.

const KIND_BITS := 5
const MAX_BODY := 2048

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


## The number of request kinds the game has (its enum's size). Override.
func _kind_count() -> int:
	return 0


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= _kind_count():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)
	return DotResult.success(true)


## Whether [param count] kinds fit in [constant KIND_BITS]. The writer masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits(count: int) -> bool:
	return count <= (1 << KIND_BITS)


func reader() -> DotNetReader:
	return DotNetReader.new(body)
