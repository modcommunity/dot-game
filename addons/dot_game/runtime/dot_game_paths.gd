class_name DotGamePaths
extends RefCounted

## Where a game's own files are, wherever this copy of it happens to live. Thirteen games had each written this file (identical bar the name); a game keeps a three-line paths script and the logic is here.
## A delivered pack mounts at [code]res://dot_cloud/<id>/<version>/[/code], so an absolute [code]res://[/code] path to the game's OWN files resolves against the host project. A script knows where it is: its [code]resource_path[/code] is the mounted path, so the game's root is that script's directory with its [code]game/[/code] segment taken off.
## [codeblock]
## # game/wo_paths.gd
## extends RefCounted
## const _SELF := preload("wo_paths.gd")
## static func root() -> String: return DotGamePaths.root_of(_SELF)
## static func rebase(path: String) -> String: return DotGamePaths.rebase_onto(path, root())
## [/codeblock]
## Built in, [method rebase_onto] returns its argument, so nothing changes there; hold paths in a [code]static var[/code], not a [code]const[/code].


## The content root of the game whose paths script is [param script]: [code]res://[/code] built in, the mount prefix delivered. Through [Resource] because a const-preloaded script is typed as its own class and [code]resource_path[/code] is not reachable on that.
static func root_of(script: Resource) -> String:
	return script.resource_path.get_base_dir().get_base_dir()


## Moves one [code]res://[/code] path onto [param here]. Anything else comes back untouched, so it is safe around a value that may already be absolute or [code]user://[/code]; format specifiers survive.
## [b]Idempotent[/b]: the publisher rewrites [code]res://[/code] in [code].tscn[/code], [code].tres[/code] and [code].import[/code] but not in [code].gd[/code], so a game holds both kinds and rebasing a rebased path would double the prefix. Taking the root as a parameter lets a suite test the mounted case, which built in is a tautology.
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path
	if path.begins_with(here):
		return path
	return here.path_join(path.substr(6))
