extends Node

## DotGameStandaloneContent: install, the gate's hold and wait, the failure message, kept manifests and the cached start, the switch.

const Stub := preload("res://examples/fixtures/standalone_cloud_stub.gd")
const ConfigStub := preload("res://examples/fixtures/standalone_config_stub.gd")
const PORT := 18765

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _server_pid := -1


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _fresh() -> void:
	DotRegistry.clear()
	DotPaths.remove_tree(DotGameStandaloneContent.MANIFEST_DIR)


func _run() -> void:
	print("dot-game: standalone content")
	DotGameStandaloneContent.client_script_override = Stub
	DotGameStandaloneContent.config_script_override = ConfigStub
	_fresh()

	var gate := DotLoadGate.new()
	add_child(gate)
	var cloud: Node = DotGameStandaloneContent.install(self, gate)
	_check(cloud != null, "installs with none registered")
	_check(DotRegistry.get_service(&"dot_cloud_client") == cloud, "registered under the cloud service name")
	_check(cloud.host_role == "client" and cloud.config.side == "client", "a player's client")
	_check(not cloud.http_base_urls.is_empty() and cloud.http_base_urls[0].begins_with("https://"), "the origin defaults to the platform")
	_check(DotGameStandaloneContent.install(self, gate) == null, "a second install finds one and does nothing")

	var before := gate.timeout_sec
	cloud.phase_changed.emit(Stub.Phase.DOWNLOADING, "Downloading")
	_check(gate.is_holding(DotGameStandaloneContent.REASON), "the gate holds while it downloads")
	_check(gate.timeout_sec >= DotGameStandaloneContent.DEFAULT_WAIT_SEC and gate.timeout_sec > before, "the gate waits far longer than 20 s")
	cloud.progress_changed.emit({"fraction": 0.5})
	_check(gate.status_text().contains("50%"), "progress is on the gate: %s" % gate.status_text())
	gate.set_meta(DotGameStandaloneContent.META_DOWNLOAD_BYTES, 400 << 20)
	cloud.progress_changed.emit({"fraction": 1.0, "done_bytes": 100 << 20})
	cloud.progress_changed.emit({"fraction": 0.5, "done_bytes": 50 << 20})
	_check(gate.status_text().contains("150 of 400 MB"), "with a known total the bytes of every slice add up: %s" % gate.status_text())
	gate.remove_meta(DotGameStandaloneContent.META_DOWNLOAD_BYTES)
	cloud.phase_changed.emit(Stub.Phase.IDLE, "")
	_check(not gate.is_holding(DotGameStandaloneContent.REASON), "the gate is released when idle")
	cloud.phase_changed.emit(Stub.Phase.DOWNLOADING, "Downloading")
	cloud.phase_changed.emit(Stub.Phase.FAILED, "offline")
	_check(not gate.is_holding(DotGameStandaloneContent.REASON), "released on failure")
	_check(gate.status_text().contains("Offline"), "a visible fallback message: %s" % gate.status_text())

	# Kept manifests, from a local origin.
	var origin := ProjectSettings.globalize_path("user://standalone_origin")
	DotPaths.remove_tree("user://standalone_origin")
	DotPaths.write_bytes("user://standalone_origin/me/art/1.0.0/manifest.json", "signed-envelope".to_utf8_buffer())
	_server_pid = OS.create_process("python3", ["-m", "http.server", str(PORT), "--bind", "127.0.0.1", "--directory", origin])
	await get_tree().create_timer(1.0).timeout
	_check(_server_pid > 0, "a local origin started")
	DotGameStandaloneContent.urls_override = PackedStringArray(["http://127.0.0.1:%d" % PORT])
	_fresh()
	cloud = DotGameStandaloneContent.install(self, gate)
	_check(cloud.http_base_urls[0].ends_with(str(PORT)), "the origin can be set")
	_check(cloud.local_search_dirs.is_empty(), "no cache, no local manifests")
	cloud.keys = PackedStringArray(["me/art@1.0.0"])
	var saved := {}
	await DotGameStandaloneContent.keep_manifests(cloud, saved)
	var kept := DotGameStandaloneContent.MANIFEST_DIR + "/me/art/1.0.0/manifest.json"
	_check(FileAccess.file_exists(kept) and FileAccess.get_file_as_string(kept) == "signed-envelope", "the manifest is kept as fetched")
	_check(saved.has("me/art@1.0.0"), "each key once")

	# Offline: the origin is gone, the next start searches the kept manifests first.
	OS.kill(_server_pid)
	cloud.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()
	cloud = DotGameStandaloneContent.install(self, gate)
	_check(cloud.local_search_dirs == PackedStringArray([DotGameStandaloneContent.MANIFEST_DIR]), "a populated cache is searched first, so it mounts offline")

	# The switch.
	cloud.queue_free()
	await get_tree().process_frame
	DotRegistry.clear()
	_check(not DotGameStandaloneContent.disabled_by_cmdline(), "on by default")
	_check(DotGameStandaloneContent.max_wait_sec() == DotGameStandaloneContent.DEFAULT_WAIT_SEC, "the wait defaults to 300 s")

	_fresh()
	DotPaths.remove_tree("user://standalone_origin")
	DotGameStandaloneContent.client_script_override = null
	DotGameStandaloneContent.config_script_override = null
	DotGameStandaloneContent.urls_override = PackedStringArray()
	print("dot-game standalone content: %d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("FAIL: ", f)
	get_tree().quit(1 if _failed > 0 else 0)
