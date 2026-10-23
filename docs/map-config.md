# Per-map settings in a game

Every game gets dot-map's per-map settings (`DotMapConfig`, dot-map's docs/map-config.md: files, wildcards, precedence, the whitelist) from dot-game. A game declares two things, the keys a map may set and (optionally) their defaults; it copies no loading code. dot-map is found by path (`res://addons/dot_map/config/dot_map_config.gd`) and never named, so a build without it applies nothing and logs that once. It needs dot-core API level 19 (`DotAddonConfig.tier_dirs`).

## On a `DotGameModule` (the server)

Override `_map_config_keys()` and call `report_map(map_id)` on every map change, which every game already does for the server list. `report_map` applies the new map's file after restoring the last map's values, and `_teardown` restores on unload.

```gdscript
func _map_config_keys() -> Dictionary:
	return {
		"sv_airaccelerate": {"type": "float", "min": 0.0, "max": 1000.0},
		"sv_gravity": {"type": "float", "min": 100.0},
		"mp_roundtime": {"type": "int", "min": 1},
	}
```

The other hooks default to what nearly every game wants: `_map_config_defaults()` (key to value for a map with no file, `{}`), `_map_config_game()` (the `cfg/game/<game>/` folder: `DotAddonConfig.game`, else `_module_name()`; set `DotAddonConfig.game` to the repository name, such as `game-arena`), and `_map_config_get(key)` / `_map_config_set(key, value)`, which read and set the server console's cvars. Override the last two for settings that are not cvars.

## On a `DotModule` not yet on `DotGameModule`

Build the helper once and call it from the map-change handler:

```gdscript
var map_config: DotGameMapConfig
func _on_map_changed(map) -> void:
	if map_config == null:
		map_config = DotGameMapConfig.for_console("game-arena", console, {"arena_surf": {"type": "int", "min": 0, "max": 1}})
	map_config.apply(String(map.id))
# and in the unload: map_config.restore()
```

## On `DotGameClient`

A client that predicts with a setting needs the same value: assign `map_config_keys` (and `map_config_defaults`, `map_config_game`) with `map_config_get_fn(key)` and `map_config_set_fn(key, value) -> bool` over its cvars, then call `client.map_changed(map_id)` when a map loads. It restores when the client leaves the tree. A client without the three assigned does nothing.

## The files

`cfg/game/<game>/dot_map/map/<name>.yml`, `<name>` a map id or a glob (`surf_*.yml`), a flat key-to-scalar mapping; the operator overrides in `cfg/server/game/<game>/dot_map/map/`. The converter writes a commented starter for every map (dot-map's docs/map-config.md).

## The check

`examples/headless_mapcfg.tscn` (needs dot-map linked at `addons/dot_map`; it says SKIPPED and exits 0 without it): the server hook, the client hook and `for_console`, with the cvars starting away from the files' values.

## Map scripts (`script.*` events)

A `DotMapWorld` replays a map's translated `lua_run` snippets to its `event_fn` as `script.set_player_speed {kind, value}`, `script.kill_players` and `script.cleanup_map {delay}` (dot-map's docs/io.md, "Map scripts"). `DotGameMapScripts` handles them for any game: put `scripts.event_fn()` in the world's hooks (or call `scripts.handle(kind, data)` from your own `event_fn`), or assign `DotGameModule.map_scripts`, which also feeds the per-map switches into the whitelist, hands over the server console, and restores on a map change and on unload.

- Every event is re-validated against dot-map's `DotMapScript.valid_op` (found by path); without dot-map everything is refused. A speed inside that range but outside `min_speed`/`max_speed` (50 to 1000 source units/s) is clamped.
- Speed: `sv_runspeed` for `run`; `walk` becomes `sv_walkspeed`, a fraction of the run speed. Replace with `speed_fn(kind, value) -> bool` or override `_set_speed`. The first value each cvar had is put back by `restore()`.
- Kill: `kill_fn() -> int` (the game's damage or round API) or override `_kill_players`; the default logs and kills nobody. Cleanup: `cleanup_fn(delay)` or `_cleanup_map`; the default logs.
- Off switches: `enabled`, `op_enabled["kill_players"] = false`, or per map in the yml with the bool keys `map_script_enabled`, `map_script_set_player_speed`, `map_script_kill_players`, `map_script_cleanup_map`.

Check: `examples/headless_mapscripts.tscn` (needs dot-map linked). No game hosts a converted map with scripts yet (mg-look-at-me's Forgotten Wing is a hand layout over that map's plan, not the BSP).
