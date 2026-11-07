extends Node

## DotGameNetIo: the delivery picks the link call, and each receive refuses the wrong end.

const CHECKS := 9

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


class FakeLink:
	extends Node
	var calls: Array = []

	func send_snapshot(peer: int, _b: PackedByteArray) -> void:
		calls.append(["snapshot", peer])

	func send_event(peer: int, _b: PackedByteArray) -> void:
		calls.append(["event", peer])

	func send_request(_b: PackedByteArray) -> void:
		calls.append(["request", 0])


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	print("dot-game: net io")
	var io := DotGameNetIo.new()
	var link := FakeLink.new()
	var bytes := PackedByteArray([1])
	io._send(3, bytes, DotNetMessage.Delivery.UNRELIABLE)
	_check(link.calls.is_empty(), "no link, no call")
	io.link = link
	io._send(3, bytes, DotNetMessage.Delivery.UNRELIABLE)
	_check(link.calls == [["snapshot", 3]], "unreliable is a snapshot")
	_check(not io.receive_event(bytes).ok, "no manager refuses an event")
	_check(io.receive_request(2, bytes).code() == DotError.CODE_STATE, "no manager refuses a request")
	_check(io.receive_snapshot(bytes).code() == DotError.CODE_FORBIDDEN, "no manager refuses a snapshot")

	var server := DotNetManager.new()
	server.is_server = true
	io.net = server
	io._send(4, bytes, DotNetMessage.Delivery.RELIABLE)
	_check(link.calls[-1] == ["event", 4], "a server's reliable send is an event")
	_check(io.receive_snapshot(bytes).code() == DotError.CODE_FORBIDDEN, "a server takes no snapshot")

	var client := DotNetManager.new()
	client.is_server = false
	io.net = client
	io._send(1, bytes, DotNetMessage.Delivery.RELIABLE)
	_check(link.calls[-1] == ["request", 0], "a client's reliable send is a request")
	var got: DotResult = io.receive_snapshot(bytes)
	_check(got == null or got.code() != DotError.CODE_FORBIDDEN, "a client takes snapshots")

	server.free()
	client.free()
	link.free()
	io.free()
	if _passed + _failed != CHECKS:
		_failed += 1
		_failures.append("ran %d checks, expected %d" % [_passed + _failed - 1, CHECKS])
	for f in _failures:
		print("FAIL: ", f)
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
