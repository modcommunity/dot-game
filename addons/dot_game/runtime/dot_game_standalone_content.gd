class_name DotGameStandaloneContent
extends RefCounted
## A content client for a game run from the project (single player, listen host), where the web shell that normally owns one is absent.

const CHANNEL := "game.standalone_content"
const CLOUD_SERVICE := &"dot_cloud_client"
## The shipped client's trust file; the fallback is a copy of its public key that travels with this addon.
const CONTENT_CONFIG := "res://client/content.json"
const FALLBACK_CONFIG := "res://addons/dot_game/data/content.json"
const DEFAULT_URL := "https://dotgames.org/content"
const REASON := &"content"


## Whether `--standalone_content=0` (or off/false) was passed: the switch that turns this off.
static func disabled_by_cmdline() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--standalone_content="):
			return a.get_slice("=", 1).to_lower() in ["0", "off", "false", "no"]
	return false


## The `{urls, config_file}` this client uses: content.json's `content_urls` when it names some, else dotgames.org.
static func settings() -> Dictionary:
	var file := CONTENT_CONFIG if FileAccess.file_exists(CONTENT_CONFIG) else FALLBACK_CONFIG
	var urls := PackedStringArray()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file)) if FileAccess.file_exists(file) else null
	if parsed is Dictionary and (parsed as Dictionary).get("content_urls", null) is Array:
		for u: Variant in (parsed as Dictionary)["content_urls"]:
			if str(u).strip_edges() != "":
				urls.append(str(u).strip_edges())
	if urls.is_empty():
		urls.append(DEFAULT_URL)
	return {"urls": urls, "config_file": file if FileAccess.file_exists(file) else ""}


## Makes and registers a content client under [param parent] when none is registered. Returns it, or null when one exists, dot-cloud is absent or this was switched off.
static func install(parent: Node, gate: DotLoadGate = null) -> Node:
	if disabled_by_cmdline() or DotRegistry.get_service(CLOUD_SERVICE) != null:
		return null
	var script := _script_of("DotCloudClient")
	var config_script := _script_of("DotCloudConfig")
	if script == null or config_script == null:
		DotLog.debug(CHANNEL, "no dot-cloud in this project; art slices cannot be fetched")
		return null
	var s := settings()
	var cloud: Node = script.new()
	cloud.name = "StandaloneCloud"
	cloud.set("host_role", "client")
	var config: Object = config_script.new()
	config.set("side", "client")
	cloud.set("config", config)
	cloud.set("config_file", s["config_file"])
	cloud.set("http_base_urls", s["urls"])
	cloud.set("manifest_url_template", "{base}/{id}/{version}/manifest.json")
	cloud.set("manifest_url_fallbacks", PackedStringArray(["{base}/{id}/manifest.json"]))
	if s["config_file"] == "":
		DotLog.warn(CHANNEL, "no client/content.json: no trusted key, so no slice can be mounted", {"looked_for": CONTENT_CONFIG})
	cloud.connect(&"phase_changed", _on_phase.bind(gate))
	parent.add_child(cloud)
	DotLog.info(CHANNEL, "standalone play fetches art slices itself", {"from": ", ".join(s["urls"]), "cache": "user://dot_cloud"})
	return cloud


static func _script_of(class_id: String) -> GDScript:
	for c: Dictionary in ProjectSettings.get_global_class_list():
		if str(c.get("class", "")) == class_id:
			return load(str(c["path"])) as GDScript
	return null


## Holds the load gate while the client works and flushes user:// when it is done; says so on the gate when it cannot reach the origin.
static func _on_phase(phase: int, text: String, gate: DotLoadGate) -> void:
	var cloud := DotRegistry.get_service(CLOUD_SERVICE)
	var phases: Dictionary = (cloud.get_script() as GDScript).get_script_constant_map().get("Phase", {}) if cloud != null else {}
	var failed := phases.has("FAILED") and phase == int(phases["FAILED"])
	var resting := cloud == null or failed or (phases.has("IDLE") and phase == int(phases["IDLE"])) or (phases.has("READY") and phase == int(phases["READY"]))
	if gate != null and is_instance_valid(gate) and not gate.is_open():
		if resting:
			gate.release(REASON)
		else:
			gate.hold(REASON, text)
		if failed:
			gate.set_progress(gate.progress(), "Offline and no cached art: drawing low-detail stand-ins")
	if resting:
		DotWeb.sync_filesystem()
	if failed:
		DotLog.warn(CHANNEL, "art slices could not be fetched; the world is drawn with stand-ins", {"why": text})
