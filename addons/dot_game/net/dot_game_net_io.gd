class_name DotGameNetIo
extends Node

## The bytes in and out of a game's net bridge, the part every bridge wrote the same way. Ten games had each written these four functions and three fields; the code of all of them is the same.
## A bridge extends this (directly, or at the bottom of its chain of partial files) and keeps only what is its game's. [member link] is duck-typed (the game's own RPC node, which needs [code]send_snapshot(peer, bytes)[/code], [code]send_event(peer, bytes)[/code] and [code]send_request(bytes)[/code]); a game that wants the typed field keeps its own and does not extend this.
## [method _send] is the callback dot-net gives its manager for outgoing bytes: the delivery decides the call, never the caller. A client's reliable send is a request, because only the server may call [code]send_event[/code].

## The dot-net manager this bridge feeds. Set by the game's attach().
var net: DotNetManager = null

## The game's RPC node.
var link: Node = null

## Where the clock learns the link's length in ms; dot-net cannot measure a transport, dot-server's heartbeat does. With no sample the clock assumes an instant link and stamps every command for a tick already simulated, so all are discarded as late.
var rtt_source: Callable = Callable()


## Where dot-net's own outgoing bytes go.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


## A reliable message from the server, on a client. The server is peer 1.
func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


## A request from [param peer_id], on the server. The id is the transport's, never the body's.
func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


## A snapshot from the server, on a client; feeds [member rtt_source] to the clock first.
func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)
