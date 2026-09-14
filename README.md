# dot-game

The wiring every server game repeats, written once.

A game in this family is a `DotModule` the server loads. Five of them exist, and before this addon each one contained the same two hundred lines: find the game object, build a `DotNetManager` with the same four non-obvious settings, construct a bridge, attach it, open its link under the server node, seal the message schema, build an identity layer and await it, load the platform module by path, build a services layer and hand it the link, keep track of who is actually playing, drive one authoritative tick, and take it all down in the reverse order. The parts that genuinely differed between them were the class names and a handful of numbers.

`DotGameModule` is that sequence. What is left for a game to write is what is actually its own.

```gdscript
extends DotGameModule

const MyBridge := preload("net/my_bridge.gd")

func _module_name() -> String: return "mygame"
func _game_service() -> StringName: return MyGame.SERVICE

func _net_config() -> DotNetConfig:
    var config := DotNetConfig.new()
    config.tick_rate = game.tick_rate
    config.snapshot_rate = 32
    return config

func _make_bridge() -> Node: return MyBridge.new()
func _make_identity() -> Node: return MyIdentity.new()
func _make_services() -> Node: return MyServices.new()

func _game_load() -> DotResult:
    add_command("mygame_status", _cmd_status, "Show the match state")
    return DotResult.success(null)
```

`examples/fixtures/test_module.gd` is a complete working one, and it is the fixture the suite drives.

## What is in it

| | |
| --- | --- |
| `DotGameModule` | The sequence, the tick, the teardown. Subclass it. |
| `DotGameNetcode` | Builds a `DotNetManager` and attaches a game's bridge. Usable on its own. |
| `DotGameRoster` | Who is in the game as opposed to who is connected, and everything that has to be told when that changes. |

## What is deliberately not in it

**No rules.** Whether a round has ended, what a team is, what the objective is, who won — those are dot-match's and dot-objective's, and they stay there. A game is free to use neither and still use this.

The test for whether something belongs here is whether every game would write it the same way with only the class names changed. A map rotation would not: some games have one and some do not, and the ones that do wire it differently. So `DotGameRoster` will tell a rotation that somebody left — through duck-typing, by `follow()`ing it — and this addon does not know what a rotation is.

## The four netcode settings, and why they are not defaults

`DotGameNetcode` fixes four things and leaves the rest to the game:

- **`auto_tick = false`** — a game's tick happens *inside* the netcode's, between applying each peer's inputs and building the snapshot, which is what the bridge arranges. A manager ticking itself as well moves every player twice, and what that looks like is a game running at double speed only when somebody is connected.
- **`config_file = ""`** — the manager reads a JSON file by default, so a stale one in `user://` sets a tick rate the game did not choose and nothing says so.
- **`local_peer_id = 1`** — the authority's id in Godot's multiplayer, which the bridge routes by.
- **`messages.seal()` last** — wire ids come from a sort of the registered type names, so a type registered after the seal renumbers every id above it and silently reinterprets every message.

Tick rate, snapshot rate and world extent have **no** default here, because there is no default that is right for two different games, and a game running at a rate it did not choose is the kind of wrong that nothing reports.

## Dependencies

dot-core, dot-server and dot-net, all three required and all three named freely.

Everything optional is reached without naming it: a map director, a vote and a services layer are duck-typed, and dot-platform's module is loaded by path. A script that so much as mentions a `class_name` the project does not have fails to parse and takes down everything that references it, so an addon that named an optional dependency would make it mandatory.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 200 godot --headless --path . res://examples/game_selftest.tscn
```

52 checks across eight sections: the sequence in order, the roster driven by the events a real server fires, the tick reaching the bridge before the game, an unload that leaves nothing running, and every path that has to unwind what it had already built.

## Licence

MIT.
