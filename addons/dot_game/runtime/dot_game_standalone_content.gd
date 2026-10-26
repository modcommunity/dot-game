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
## What dot-map's `DotMapStore` sets on the gate: bytes the chosen map's slices still need.
const META_DOWNLOAD_BYTES := &"download_bytes"
## Signed manifests kept for the next offline start, laid out as `{id}/{version}/manifest.json` so dot-cloud reads them as a local source.
const MANIFEST_DIR := "user://dot_standalone_manifests"
## Seconds the load gate waits for slices; `--standalone_content_wait=` overrides.
const DEFAULT_WAIT_SEC := 300.0

## Test seam: replaces [constant CONTENT_CONFIG]'s urls when non-empty.
static var urls_override: PackedStringArray = PackedStringArray()
## Test seam: a script used for DotCloudClient and DotCloudConfig when set (dot-cloud is not linked into every project).
static var client_script_override: GDScript = null
static var config_script_override: GDScript = null


## Whether `--standalone_content=0` (or off/false) was passed: the switch that turns this off.
static func disabled_by_cmdline() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--standalone_content="):
			return a.get_slice("=", 1).to_lower() in ["0", "off", "false", "no"]
	return false


## The most seconds the gate holds for slices (`--standalone_content_wait=`).
static func max_wait_sec() -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--standalone_content_wait="):
			return maxf(1.0, a.get_slice("=", 1).to_float())
	return DEFAULT_WAIT_SEC


## The `{urls, config_file}` this client uses: content.json's `content_urls` when it names some, else dotgames.org.
static func settings() -> Dictionary:
	var file := CONTENT_CONFIG if FileAccess.file_exists(CONTENT_CONFIG) else FALLBACK_CONFIG
	var urls := PackedStringArray()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file)) if FileAccess.file_exists(file) else null
	if parsed is Dictionary and (parsed as Dictionary).get("content_urls", null) is Array:
		for u: Variant in (parsed as Dictionary)["content_urls"]:
			if str(u).strip_edges() != "":
				urls.append(str(u).strip_edges())
	if not urls_override.is_empty():
		urls = urls_override
	if urls.is_empty():
		urls.append(DEFAULT_URL)
	return {"urls": urls, "config_file": file if FileAccess.file_exists(file) else ""}


## Makes and registers a content client under [param parent] when none is registered. Returns it, or null when one exists, dot-cloud is absent or this was switched off.
static func install(parent: Node, gate: DotLoadGate = null) -> Node:
	if disabled_by_cmdline() or DotRegistry.get_service(CLOUD_SERVICE) != null:
		return null
	var script := client_script_override if client_script_override != null else _script_of("DotCloudClient")
	var config_script := config_script_override if config_script_override != null else _script_of("DotCloudConfig")
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
	if DirAccess.dir_exists_absolute(MANIFEST_DIR):
		cloud.set("local_search_dirs", PackedStringArray([MANIFEST_DIR]))
		DotLog.debug(CHANNEL, "kept manifests are searched first, so a cached slice mounts offline", {"dir": MANIFEST_DIR})
	if s["config_file"] == "":
		DotLog.warn(CHANNEL, "no client/content.json: no trusted key, so no slice can be mounted", {"looked_for": CONTENT_CONFIG})
	var saved := {}
	cloud.connect(&"phase_changed", _on_phase.bind(gate, cloud, saved))
	cloud.connect(&"progress_changed", _on_progress.bind(gate, {"done": 0, "last": 0}))
	parent.add_child(cloud)
	DotLog.info(CHANNEL, "standalone play fetches art slices itself", {"from": ", ".join(s["urls"]), "cache": "user://dot_cloud"})
	return cloud


static func _script_of(class_id: String) -> GDScript:
	for c: Dictionary in ProjectSettings.get_global_class_list():
		if str(c.get("class", "")) == class_id:
			return load(str(c["path"])) as GDScript
	return null


static func _phases(cloud: Object) -> Dictionary:
	return (cloud.get_script() as GDScript).get_script_constant_map().get("Phase", {}) if cloud != null else {}


static func _on_progress(p: Dictionary, gate: DotLoadGate, state: Dictionary) -> void:
	if gate == null or not is_instance_valid(gate) or gate.is_open() or not gate.is_holding(REASON):
		return
	var f := float(p.get("fraction", 0.0))
	var total := int(gate.get_meta(META_DOWNLOAD_BYTES, 0))
	if total <= 0:
		gate.set_progress(gate.progress(), "Downloading map art: %d%%" % int(f * 100.0))
		return
	# Each slice reports its own bytes from zero; a drop means the next slice began.
	var now := int(p.get("done_bytes", 0))
	state["done"] = int(state["done"]) + (now - int(state["last"]) if now >= int(state["last"]) else now)
	state["last"] = now
	var done := mini(int(state["done"]), total)
	gate.set_progress(float(done) / float(total), "Downloading map art: %d of %d MB" % [done >> 20, total >> 20])


## Holds the gate (for up to [method max_wait_sec]) while the client works, keeps manifests when it is done, and says so when it cannot reach the origin.
static func _on_phase(phase: int, text: String, gate: DotLoadGate, cloud: Node, saved: Dictionary) -> void:
	var phases := _phases(cloud)
	var failed := phases.has("FAILED") and phase == int(phases["FAILED"])
	var ready := phases.has("READY") and phase == int(phases["READY"])
	var resting := failed or ready or (phases.has("IDLE") and phase == int(phases["IDLE"]))
	if gate != null and is_instance_valid(gate) and not gate.is_open():
		if resting:
			gate.release(REASON)
		else:
			if not gate.is_holding(REASON):
				gate.timeout_sec = maxf(gate.timeout_sec, max_wait_sec())
			gate.hold(REASON, text)
		if failed:
			gate.set_progress(gate.progress(), "Offline and no cached art: drawing low-detail stand-ins")
	if ready:
		keep_manifests(cloud, saved)
	if resting:
		DotWeb.sync_filesystem()
	if failed:
		DotLog.warn(CHANNEL, "art slices could not be fetched; the world is drawn with stand-ins", {"why": text})


## Saves the signed manifest of every acquired slice (fetched again, a few KB each) so the next start works offline. Verified again on read, so the copy cannot widen trust.
static func keep_manifests(cloud: Node, saved: Dictionary) -> void:
	var http := DotHttp.new()
	cloud.add_child(http)
	for key: String in cloud.call("acquired_keys"):
		if saved.has(key) or key.find("@") <= 0:
			continue
		saved[key] = true
		var id := key.get_slice("@", 0)
		var version := key.get_slice("@", 1)
		var path := MANIFEST_DIR.path_join(id).path_join(version).path_join("manifest.json")
		if FileAccess.file_exists(path):
			continue
		for url: String in cloud.call("manifest_urls_for", StringName(id), version):
			if not (url.begins_with("http://") or url.begins_with("https://")):
				continue
			var got: DotResult = await http.get_bytes(url)
			if got.ok:
				var wrote := DotPaths.write_bytes(path, got.value)
				if not wrote.ok:
					DotLog.warn(CHANNEL, "a slice manifest could not be kept", {"path": path})
				break
	http.queue_free()
