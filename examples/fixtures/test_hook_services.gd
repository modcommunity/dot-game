extends DotGameServices

## [DotGameServices] with the hooks a subclass answers, for the suite's "hooks" section.
##
## This project has none of dot-chat, dot-voice or dot-moderation, so the layers the hooks
## reach are stand-ins: [FakeChat] answers `backlog_for` the way dot-chat's router does and
## [FakeLink] records what the base's fan-out sends. What is under test is the base's
## decision — whether the backlog goes at seating or waits for the game — not dot-chat.

## What [method _peer_can_receive] answers.
var receive := true


func _peer_can_receive(_peer_id: int) -> bool:
	return receive


## Two backlog rows for anybody, like a channel with `backlog = 2`.
class FakeChat extends Node:
	func backlog_for(_peer_id: int) -> Array:
		return [{"t": "first"}, {"t": "second"}]

	func forget(_peer_id: int) -> void:
		pass


## What a bridge's link would be: the node with `send_chat` on it.
class FakeLink extends Node:
	var sent: Array = []

	func send_chat(peer_id: int, wire: Dictionary) -> void:
		sent.append([peer_id, wire])
