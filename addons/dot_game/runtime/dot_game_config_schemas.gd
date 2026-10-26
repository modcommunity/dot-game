class_name DotGameConfigSchemas
extends RefCounted

## The profile schemas of a game's grouped `config_<file>` kinds, for dot-profile's profile_check (any registered class with this static is a provider, so a game enables `profiles: true` with no provider of its own).

const MAKER := "static func make_binder("
## Directories that never hold a game's config (addons carry their own providers).
const SKIP_DIRS := ["addons", "maps", "assets", "images", "cfg", "build"]


## Every game config script (registered or not: configs rarely have a `class_name`) that declares `static func make_binder(config, json_path)` contributes its binder's sets, kind -> field Array.
static func profile_schemas() -> Dictionary:
	var scripts: Array = []
	_scan("res://", scripts)
	return schemas_for(scripts)


static func _scan(dir: String, scripts: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") and FileAccess.get_file_as_string(dir.path_join(f)).contains(MAKER):
			scripts.append(load(dir.path_join(f)))
	for d in DirAccess.get_directories_at(dir):
		if not (d.begins_with(".") or d in SKIP_DIRS):
			_scan(dir.path_join(d), scripts)


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
