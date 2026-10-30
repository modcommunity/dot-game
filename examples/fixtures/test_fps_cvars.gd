extends RefCounted

## Stands in for dot-player-controller's DotFpsCvars: the suite runs without that addon.

var targets: Array = []


func add_target(target: Object) -> Object:
	targets.append(target)
	return self


func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []
	for target: Object in targets:
		for spec: Dictionary in target.call(&"cvar_specs"):
			made.append(add.call(spec["name"], str(spec["value"]), spec["description"], flags))
	return made
