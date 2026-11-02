class_name DotGameLink
extends RefCounted

## Puts a game's RPC link node under a parent AND ties its life to the bridge that made it.
##
## The link must sit at a fixed name under the server node because RPCs route by node path; a bare `add_child` outlives the bridge and the next load's link gets renamed, silently dropping every RPC. It is renamed away and `queue_free`d rather than removed, which logs errors while the parent is leaving the tree. Duck-typed: a link and an owner are any Node.

## The prefix a retired link carries until the queue frees it.
const RETIRED := "retired_"

## How long a retired link stays in the tree. Matches DotGameManager.RETIRED_SECONDS.
const RETIRED_SECONDS := 10.0


## Adds [param link] under [param parent] as [param link_name] and frees it when [param owner]
## leaves the tree. A link of the same name already there (a module that was not unloaded
## cleanly) is retired first, so the new one always gets the name.
static func attach(link: Node, parent: Node, owner: Node, link_name: StringName) -> void:
	var stale := parent.get_node_or_null(NodePath(String(link_name)))
	if stale != null and stale != link:
		retire(stale)
	link.name = link_name
	parent.add_child(link)
	_free_retired_named(parent, link_name, link)
	# add_child renames on a clash without a word, and a renamed link is the bug this class
	# exists to stop: every RPC to it is lost. Say so where it happened.
	if link.name != link_name:
		push_error("DotGameLink: %s was renamed %s; RPCs to it will be lost" % [link_name, link.name])
	# A link that was never given a bridge would never be freed: say so where it is made.
	if owner == null:
		push_error("DotGameLink.attach needs the bridge that owns the link")
		return
	# By id: a bound Object that is freed before the signal fires cannot be converted to the
	# argument, and the engine logs an error instead of calling.
	owner.tree_exiting.connect(_retire_id.bind(link.get_instance_id()), CONNECT_ONE_SHOT)


## Frees at once every retired link of [param link_name] under [param parent].
## A client's cached id resolves to the old object before the path, so a retired link of the same name would swallow its input.
## A link retired by a switch to another game keeps its wait.
static func _free_retired_named(parent: Node, link_name: StringName, keep: Node) -> void:
	var prefix := "%s%s_" % [RETIRED, link_name]
	for child in parent.get_children():
		if child == keep or child.is_queued_for_deletion():
			continue
		var n := String(child.name)
		if n.begins_with(prefix) and n.substr(prefix.length()).is_valid_int():
			child.queue_free()


static func _free_id(id: int) -> void:
	var node := instance_from_id(id) as Node
	if node != null and not node.is_queued_for_deletion():
		node.queue_free()


static func _retire_id(id: int) -> void:
	retire(instance_from_id(id) as Node)


## Frees [param link] without touching its parent's child list; safe while the parent is busy, and twice.
##
## The node waits [constant RETIRED_SECONDS] with its bridge cleared so a client still sending to the old game logs no "Node not found". [method attach] frees any retired link of the name it takes.
static func retire(link: Node) -> void:
	if link == null or not is_instance_valid(link):
		return
	# Renamed even if already queue_freed: a queued node keeps its name until frame end.
	# Unique rather than a counter, since two retirements can land in one frame.
	if not String(link.name).begins_with(RETIRED):
		link.name = "%s%s_%d" % [RETIRED, link.name, link.get_instance_id()]
	if link.is_queued_for_deletion():
		return
	# Kept RETIRED_SECONDS, not freed at once: in-flight client calls would log "Node not found"
	# and "Failed to get cached node" on every switch. DotGameManager does the same.
	# With its bridge gone the link drops what it receives.
	if not link.is_inside_tree():
		link.queue_free()
		return
	if "bridge" in link:
		link.set("bridge", null)
	link.get_tree().create_timer(RETIRED_SECONDS, true, false, true).timeout.connect(
		_free_id.bind(link.get_instance_id()))
