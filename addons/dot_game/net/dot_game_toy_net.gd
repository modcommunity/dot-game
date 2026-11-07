class_name DotGameToyNet
extends DotNetBehaviour

## One of the map's toys on the wire (dot-props' [DotPropToy]): where its moving part is and how it is turned, whether it is on, and how often it has been used. Eleven games had each written this file; the code of all of them is the same.
## The server's physics, never predicted: rigid-body solvers differ across machines, so the client's toy is frozen and posed from these ([method DotPropToy.show_state]). Paired by index: both ends build the same toys in map order, so a TOYS event carries only net ids; a client registers a toy before its map is built because a snapshot is read no further than its first unknown entity.
## Use count, not a use event: a honk or bounce moves [member net_count] by one (eight bits, wraps) and the client plays the sound when it moves, so a lost packet costs a late sound.
## [member toy] is duck-typed (dot-props is not a dependency): it needs [code]state_transform()[/code], [code]on[/code], [code]count[/code] and [code]show_state(position, rotation, on, count)[/code], which [DotPropToy] has.

var toy: Object = null

var net_position: Vector3 = Vector3.ZERO
var net_rotation: Quaternion = Quaternion.IDENTITY
var net_on: bool = false
var net_count: int = 0

## Whether a state has arrived: before one the fields are zero, and a toy posed from them would jump to the world's origin.
var _seen: bool = false


func _register_net_vars() -> void:
	replicate(&"net_position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
	# Nine bits an element, under a degree: nobody lines a ball up to a degree.
	replicate(&"net_rotation", DotNetVar.Type.QUATERNION).bits(9).interpolated()
	replicate(&"net_on", DotNetVar.Type.BOOL)
	replicate(&"net_count", DotNetVar.Type.UINT).bits(8)


## Authority only: the toy's state into the replicated fields.
func pull() -> void:
	# Out of the tree is a stage rebuilt inside the netcode's own tick: the manager is still
	# walking the list it took before, and a toy taken out has no transform to give.
	if toy == null or not is_instance_valid(toy) or not (toy as Node).is_inside_tree():
		return
	var at: Transform3D = toy.state_transform()
	net_position = at.origin
	net_rotation = at.basis.get_rotation_quaternion()
	net_on = toy.on
	net_count = toy.count


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


func _net_state_applied(_tick: int) -> void:
	_seen = true
	_draw()


## Every frame between snapshots, or a ball steps at the snapshot rate.
func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if not _seen or toy == null or not is_instance_valid(toy) or (identity != null and identity.is_authoritative):
		return
	toy.show_state(net_position, net_rotation, net_on, net_count)
