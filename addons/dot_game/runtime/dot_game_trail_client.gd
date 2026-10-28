class_name DotGameTrailClient
extends RefCounted

## The client half of player trails: asks the server to equip, and draws a ribbon behind every player the server says wears one. Trail ids are all that arrives; an id the loaded pack does not know draws nothing.

const CHANNEL := "game.trail"
## The server rule advertising its trail pack as "<content id>@<version>".
const PACK_CVAR := "sv_trail_pack"
const EMITTER_SCRIPT := "res://addons/dot_trail/dot_trail_emitter.gd"
const EMITTER_META := &"dot_trail_emitter"

signal changed(actor: int, id: String)

## A dot-trail DotTrailRegistry, filled by the pack (see [method fetch_pack]).
var registry: Object
## func(actor: int) -> Node3D: the figure to follow, or null when it is not in the scene yet.
var node_for: Callable = Callable()
## actor peer id -> trail id.
var worn: Dictionary = {}

var _net: DotNetManager = null


## Registers the type and listens. Call before the schema is sealed.
func attach(net: DotNetManager, p_registry: Object) -> DotResult:
	var made := DotGameTrailMessage.register(net)
	if not made.ok:
		return made
	_net = net
	registry = p_registry
	return net.messages.on(DotGameTrailMessage.NAME, _on_message)


## Asks the server to wear [param id] ("" takes it off). The server decides; the answer arrives as [signal changed].
func request(id: String) -> DotResult:
	if _net == null:
		return DotResult.fail(DotError.CODE_STATE, "trail client is not attached")
	var m := DotGameTrailMessage.new()
	m.id = id
	return _net.send(m)


## Draws again: after the pack arrived late, or a figure spawned.
func refresh() -> void:
	for actor: int in worn:
		_apply(actor)


## "<id>@<version>" from the server's rules, or an empty array.
static func pack_from_rules(rules: Dictionary) -> PackedStringArray:
	var parts := String(rules.get(PACK_CVAR, "")).strip_edges().split("@")
	if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
		return PackedStringArray()
	return parts


## The pre-join step: ensures the server's one trail pack through a DotCloudClient (duck-typed) and loads it into [member registry]. Success holds the trail count; a failure means join without trails.
func fetch_pack(cloud: Object, rules: Dictionary) -> DotResult:
	var pack := pack_from_rules(rules)
	if pack.is_empty():
		return DotResult.success(0)
	var pack_script := load("res://addons/dot_trail/dot_trail_pack.gd") as GDScript
	if pack_script == null or registry == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "dot-trail is not linked")
	var res: DotResult = await pack_script.call(&"fetch", cloud, pack[0], pack[1], registry)
	if res.ok:
		refresh()
	return res


func _on_message(message: DotNetMessage) -> void:
	var m := message as DotGameTrailMessage
	if m == null or m.actor <= 0:
		return
	if m.id.is_empty():
		worn.erase(m.actor)
	else:
		worn[m.actor] = m.id
	_apply(m.actor)
	changed.emit(m.actor, m.id)


func _apply(actor: int) -> void:
	var figure: Node = node_for.call(actor) if node_for.is_valid() else null
	if figure == null or not is_instance_valid(figure):
		return
	var old: Variant = figure.get_meta(EMITTER_META) if figure.has_meta(EMITTER_META) else null
	if old is Node and is_instance_valid(old):
		(old as Node).queue_free()
		figure.remove_meta(EMITTER_META)
	var id: String = worn.get(actor, "")
	var def: Object = registry.call(&"get_def", id) if registry != null and not id.is_empty() else null
	var script := load(EMITTER_SCRIPT) as GDScript
	if def == null or script == null:
		return
	var emitter: Node = script.new()
	emitter.set(&"registry", registry)
	figure.add_child(emitter)
	emitter.call(&"set_trail", def)
	figure.set_meta(EMITTER_META, emitter)
