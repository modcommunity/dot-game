class_name DotGameLink
extends RefCounted

## Puts a game's RPC link node under a parent AND ties its life to the bridge that made it.
##
## [b]Why this exists.[/b] Godot routes an RPC by the receiver's node path, so a game's link
## has to sit at a fixed name under the server node (`Server/<NODE_NAME>`), not under the
## bridge. A link added with a bare [code]parent.add_child[/code] therefore outlives the
## bridge: nothing frees it when the module unloads, the next load adds a second one, Godot
## renames the live one [code]@Node@n[/code], and every RPC to a real client is dropped
## because the path no longer matches. Nothing errors.
##
## [b]Why it does not call [code]remove_child[/code].[/b] The obvious fix, an [code]_exit_tree[/code]
## that removes the link from its parent, logs "Parent node is busy adding/removing children"
## whenever the whole server tree is torn down at once, because the parent is itself in the
## middle of leaving. Here the stale link is renamed out of the way (which frees the name
## at once, so the next link gets it) and [code]queue_free[/code]d; the engine removes it
## when it is safe, and it is the parent's business, not ours, when that is.
##
## Duck-typed on purpose: a link is any Node, and [param owner] is any Node (the bridge).

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


## Frees at once every retired link of [param link_name] under [param parent]. A client's cache
## id resolves to the cached OBJECT before the node path, so while a retired link of the name
## the new link now holds is still in the tree, the client's input lands on it (bridge null) and
## is dropped for the whole grace period. Nobody else is reusing that name, so no in-flight RPC
## has anything to gain from waiting; a link retired by a switch to another game keeps its wait.
static func _free_retired_named(parent: Node, link_name: StringName, keep: Node) -> void:
	var prefix := "%s%s_" % [RETIRED, link_name]
	for child in parent.get_children():
		if child == keep or child.is_queued_for_deletion():
			continue
		var n := String(child.name)
		if n.begins_with(prefix) and n.substr(prefix.length()).is_valid_int():
			child.queue_free()


static func _retire_id(id: int) -> void:
	retire(instance_from_id(id) as Node)


## Frees [param link] without touching its parent's child list. Safe while the parent is
## busy, and safe to call twice.
##
## The retired node stays in the tree for [constant RETIRED_SECONDS], bridge cleared, so a
## client still sending to the old game (it keeps going until LOAD_GAME reaches it) does not
## log "Node not found". The engine's RPC cache routes by instance id before path, so a retired
## link that shares its name with a newer one would swallow that client's input: [method attach]
## therefore queue_frees any retired link of the name it takes. Only a link nobody re-attaches
## under (a switch to another game) waits out the full grace period.
static func retire(link: Node) -> void:
	if link == null or not is_instance_valid(link):
		return
	# Renamed even when something else already queue_freed it: a queued node still holds its
	# name until the end of the frame, so skipping the rename would let add_child rename the
	# new link instead. Unique, so the name is free this instant; not a counter, because two
	# retirements can land in one frame.
	if not String(link.name).begins_with(RETIRED):
		link.name = "%s%s_%d" % [RETIRED, link.name, link.get_instance_id()]
	if link.is_queued_for_deletion():
		return
	# Kept in the tree for RETIRED_SECONDS rather than freed at once. A client keeps sending
	# to the old game until LOAD_GAME reaches it (a game's input every frame), and Godot
	# caches the receiving node's OBJECT under the id it gave the client, dropping that entry
	# when the node leaves the tree. Freed at once, every one of those in-flight calls logged
	# "Node not found: Server/<name>" and "Failed to get cached node" on the server, in every
	# game, on every switch. DotGameManager does the same for what a game leaves under the
	# server node. A link whose bridge is gone drops what it receives (`bridge` is null).
	if not link.is_inside_tree():
		link.queue_free()
		return
	if "bridge" in link:
		link.set("bridge", null)
	link.get_tree().create_timer(RETIRED_SECONDS, true, false, true).timeout.connect(
		func() -> void:
			if is_instance_valid(link):
				link.queue_free()
	)
