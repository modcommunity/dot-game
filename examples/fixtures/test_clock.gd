extends Node

## Stands in for a dot-vote DotVoteDirector or a dot-map DotMapSession: anything under a
## module that answers follow_hibernation(server). Neither addon is installed here, which is
## the point -- the module finds it by the method, not by a class.

var followed := 0
var heard: Array[bool] = []


func follow_hibernation(server: Object) -> bool:
	followed += 1
	if not server.is_connected("hibernation_changed", _on_hibernation):
		server.connect("hibernation_changed", _on_hibernation)
	return true


func _on_hibernation(on: bool) -> void:
	heard.append(on)
