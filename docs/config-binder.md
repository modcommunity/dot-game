# DotGameConfigBinder: a game's `*Config` as an operator surface

A game's `DotConfig` subclass holds 40 to 177 tunables that only env, argv and a JSON file reached. The binder makes every exported field (bool, int, float, String, PackedStringArray) reachable like a cvar and like a profile, with no per-field code.

## Use

```gdscript
# server scene, where the config is built today
var config := HsConfig.new()
var binder := DotGameConfigBinder.create(config, "hide-n-seek", "hs", "user://cfg/hideseek.json")
var res := binder.load_layers()
if not res.ok:
    DotGameConfigBinder.fail_boot(get_tree(), res)   # ERROR line + non-zero exit
    return
# the module, once it has a console
binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, console.has_name)   # hs_<field>
binder.bind_commands(add_command)                     # hs_config_diff [save], hs_config_dump
binder.attach(profile_runtime)                        # workbench: kind `config`, id `game`
```

Set `replicate_keys` / `replicate_groups` before `bind_cvars` for fields a client predicts with (the cvar then gets `FLAG_REPLICATED`); `skip_keys` hides fields. Pass `console.has_name` as `exists` so a cvar the game already binds by hand keeps its own code; remove the hand-written ones as they are covered.

## Layers (weakest first) and where each value came from

code defaults, `json_path`, `cfg/game/<game>/config/game.yml`, `cfg/server/game/<game>/config/game.yml` (and the other roots `DotProfileSet` reads), `PROFILE_CONFIG_GAME_<KEY>` / `--profile.config/game.<key>=`, the config's own `<PREFIX>_*` env and `--prefix-*` argv, then at runtime cvars (`cvar`) and the workbench (`workbench`). `load_layers()` logs one INFO per layer with the keys it set, and `report_lines()` / `<prefix>_config_dump` list every field with its value and layer; `source_of(key)` returns the layer. A yml file is a flat mapping of field names, e.g. `hide_seconds: 30.0`.

## Strict mode

`strict` defaults to on for a dedicated or headless server outside the editor (`--config-strict` / `--no-config-strict` override). Strict makes `load_layers()` fail, with every problem logged at ERROR, on an unknown key in the JSON, yml or env/argv, unreadable JSON, a bad profile file (out of range, wrong type, bad yml), or a failed `validate()`. Not strict, the same problems are logged and the boot continues on what loaded. `check_map(requested, known)` does the same for `--map`: strict fails on an unknown map, otherwise it warns and returns `""` (use the default). A bad env/argv *value* (not key) is still only a WARN from `DotConfig`.

## The profile surface

`profile_set()` is a `DotProfileSet` of kind `config` whose schema is `schema()`: per field `key`, `type`, `default`, `group` (`@export_group`), `description` (first paragraph of the `##` comment), `min`/`max`/`step` (`@export_range`) and `enum` + `options` (`@export_enum`). `attach(runtime)` adds it to a `DotProfileRuntime`, so `DotWorkbenchApi` lists it, validates edits with those bounds, saves to `cfg/server/game/<game>/config/game.yml`, and the field and cvar follow every edit. Descriptions come from the script source; a build that ships no source reads `res://cfg/game/<game>/config/schema.json`, written by `write_schema(path)`.

## Giving edits back as defaults

`diff()` is every field that differs from the code defaults; `diff_yaml()` is the same as a `config` profile; `<prefix>_config_diff save` writes it to `user://config_diff_<game>.yml`. Copy that file to `cfg/game/<game>/config/game.yml` in the game repository and the values are the shipped defaults (then change the code defaults when convenient and delete the file).

Test: `examples/headless_config.tscn`.
