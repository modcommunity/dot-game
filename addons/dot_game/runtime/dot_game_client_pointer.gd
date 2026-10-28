class_name DotGameClientPointer
extends RefCounted

## Holds [DotGameClient]'s pointer for nodes in the [code]dot_pointer_modal[/code] group (dot-ui's ballot) while their [code]pointer_mode_changed(on)[/code] says they freed the mouse. Duck-typed by group and signal, so this names nothing in dot-ui.


static func wire(c: DotGameClient) -> void:
	if not c.is_inside_tree():
		return
	var tree := c.get_tree()
	if not tree.node_added.is_connected(c._on_node_added):
		tree.node_added.connect(c._on_node_added)
	for node in tree.get_nodes_in_group(&"dot_pointer_modal"):
		adopt(node, c)


static func adopt(node: Node, c) -> void:
	if not node.is_in_group(&"dot_pointer_modal") or not node.has_signal(&"pointer_mode_changed"):
		return
	# A bound static Callable compares equal across clients: connect would refuse the second, so a lambda.
	var mark := StringName("dot_pointer_held_by_%d" % c.get_instance_id())
	if node.has_meta(mark):
		return
	node.set_meta(mark, true)
	node.connect(&"pointer_mode_changed", func(on: bool) -> void: on_mode_changed(on, c, node))
	node.tree_exiting.connect(c.release_pointer.bind(node))
	if node.has_method(&"is_pointer_mode") and bool(node.call(&"is_pointer_mode")):
		c.hold_pointer(node)


static func on_mode_changed(on: bool, c, node: Node) -> void:
	if not is_instance_valid(c):
		return
	if on:
		c.hold_pointer(node)
	else:
		c.release_pointer(node)


static func escape_frees(c: DotGameClient, event: InputEvent) -> bool:
	if not c.escape_releases_pointer or not c.capture_pointer or not c._set_up or c.gate_only:
		return false
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_ESCAPE:
		return false
	if not c._pointer_captured() or c.is_menu_open() or c._chat_typing() or c._busy():
		return false
	c._free_pointer()
	return true


static func click_captures(c: DotGameClient, event: InputEvent) -> void:
	if not c.capture_pointer or not c._set_up or c.gate_only:
		return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	if c.is_menu_open() or c._chat_typing() or c._busy() or not c.is_shown() or not c._pointer_wanted():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
