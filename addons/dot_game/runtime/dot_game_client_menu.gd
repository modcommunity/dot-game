class_name DotGameClientMenu
extends RefCounted

## The board and map-vote wiring of [DotGameClient]'s adopted menu; the client keeps the state.


static func wire_board(c: DotGameClient) -> void:
	var board: Object = c.board
	if board == null:
		return
	if c.board_prepare_fn.is_valid() and not c._prepared_boards.has(board.get_instance_id()):
		c._prepared_boards.append(board.get_instance_id())
		c.board_prepare_fn.call(board)
	if not c.offline and c.link != null and c.link.has_signal(&"scoreboard_received") and board.has_method(&"feed_from"):
		board.call(&"feed_from", c.link)
	elif c.board_snapshot_fn.is_valid():
		board.set(&"source", c.board_snapshot_fn)


static func wire_maps(c: DotGameClient) -> void:
	var owner: Object = c.settings if c.settings != null and c.settings.has_method(&"use_maps") else c.menu
	if not (c.maps_rows_fn.is_valid() and c.maps_change_fn.is_valid() and owner != null \
			and owner.has_method(&"use_maps")):
		return
	var made: Variant = owner.call(&"use_maps", c.maps_rows_fn, c.maps_change_fn)
	c.maps = made if made is Object else null
	if c.maps == null:
		return
	if c.maps_title != "":
		c.maps.set(&"title", c.maps_title)
	if c.maps_noun != "":
		c.maps.set(&"noun", c.maps_noun)
	# Played offline beside a link (--offline): there is no server to ask.
	if c.offline:
		c.maps.set(&"link_service", &"")
