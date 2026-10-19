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


## Adds [param link] under [param parent] as [param link_name] and frees it when [param owner]
## leaves the tree. A link of the same name already there (a module that was not unloaded
## cleanly) is retired first, so the new one always gets the name.
static func attach(link: Node, parent: Node, owner: Node, link_name: StringName) -> void:
	var stale := parent.get_node_or_null(NodePath(String(link_name)))
	if stale != null and stale != link:
		retire(stale)
	link.name = link_name
	parent.add_child(link)
	# A link that was never given a bridge would never be freed: say so where it is made.
	if owner == null:
		push_error("DotGameLink.attach needs the bridge that owns the link")
		return
	owner.tree_exiting.connect(retire.bind(link), CONNECT_ONE_SHOT)


## Frees [param link] without touching its parent's child list. Safe while the parent is
## busy, and safe to call twice.
static func retire(link: Node) -> void:
	if link == null or not is_instance_valid(link) or link.is_queued_for_deletion():
		return
	# Unique, so the name is free this instant. Not a counter: two retirements in a frame.
	link.name = "%s%s_%d" % [RETIRED, link.name, link.get_instance_id()]
	link.queue_free()
