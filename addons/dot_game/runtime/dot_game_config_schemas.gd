class_name DotGameConfigSchemas
extends RefCounted

## The profile schemas of a game's grouped `config_<file>` kinds, for dot-profile's profile_check (any registered class with this static is a provider, so a game enables `profiles: true` with no provider of its own).

const MAKER := "static func make_binder("


## Every registered game config script that declares `static func make_binder(config, json_path)` contributes its binder's sets, kind -> field Array.
static func profile_schemas() -> Dictionary:
	var scripts: Array = []
	for c in ProjectSettings.get_global_class_list():
		if FileAccess.get_file_as_string(c["path"]).contains(MAKER):
			scripts.append(load(c["path"]))
	return schemas_for(scripts)


## [method profile_schemas] over the given config scripts.
static func schemas_for(scripts: Array) -> Dictionary:
	var out := {}
	for s: Script in scripts:
		if s == null or not s.has_method("make_binder"):
			continue
		var binder: DotGameConfigBinder = s.call("make_binder", s.new())
		for set: DotProfileSet in binder.profile_sets():
			out[set.rel_path] = set.schema
	return out
