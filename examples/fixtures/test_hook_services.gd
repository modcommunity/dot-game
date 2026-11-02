extends DotGameServices

## [DotGameServices] with the hooks a subclass answers, for the suite's "hooks" section.
##
## The layers the hooks reach are stand-ins ([FakeChat], [FakeLink]); under test is the base's decision, whether the backlog goes at seating or waits for the game.

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
