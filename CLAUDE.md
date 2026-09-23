# dot-game

The wiring every server game repeats.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first. This file is only what is specific to this addon.

**dot-core, dot-server and dot-net are required.** Everything else a game touches — a map director, a vote, a services layer, dot-platform — is duck-typed or loaded by path and named nowhere.

## Why this exists, measured rather than asserted

Five games were written before it. Their modules are 1,046, 1,154, 1,816, 1,642 and 837 lines, and a diff of any two of them is almost entirely renamed types: `_build_netcode`, `_build_identity`, `_build_services`, `_build_vote`, a net bridge, `_joined`, `_tick`, `_on_client_spawn`, `_on_client_disconnected`, `_build_query_provider`, `_register_game`. `arena_module._build_identity` and `g2g_module._build_identity` differ by one assigned property and a variable name, comments included.

That much duplication is a nuisance. What makes it a *bug* is the other measurement: **two of the five got the same line wrong.**

```gdscript
var session := server.session_by_userid(event.get_int("peer_id"))
```

`client_spawn` carries `userid` and `name`. It does not carry `peer_id`. So that lookup asked for session 0, found null, and returned — and **nobody ever joined those dedicated servers**, silently, for as long as those modules existed. A null session is a legitimate thing to find, so nothing errored; a dedicated-server suite passes without noticing, because it never connects a client.

Five copies of a thing is five chances to write it wrong and five places to fix it. The argument for a base class here is not tidiness, it is that there is one line to be right.

## The split, and where the line is

**This holds no rules.** Whether a round has ended, what a team is, what the objective is and who won are dot-match's and dot-objective's. A game may use neither and still use this.

The test for whether something belongs here: **would every game write it the same way with only the class names changed?**

- The netcode's four non-obvious settings — yes. Every game got them identically right because each copied the last.
- The order identity comes up in relative to services — yes, and the reason is a real bug (a backbone assigned after `setup` is one the relay has already decided it does not have).
- A map rotation — **no.** Some games have one, some do not, and the ones that do wire it differently. So `DotGameRoster.follow()` will tell a rotation when somebody leaves, through duck-typing, and this addon does not know what a rotation is.

## What is fatal and what is not

`_module_load` refuses on two things and shrugs at everything else:

| | |
| --- | --- |
| No game object under `_game_service()` | **Fatal.** A module that loads and does nothing leaves a server admitting players into a match that does not exist, and the symptom is players who connect and never spawn. |
| The netcode would not start | **Fatal**, for the same reason. |
| The identity layer failed | Logged. A server where everybody is a guest is a configuration. |
| The services layer failed | Logged. A server with no chat is a server nobody stays on — but it *is* a server, and taking the game down because a punishment file was unreadable makes a permissions mistake cost the players what they came for. |
| `_game_load()` refused | Fatal, **and it unwinds** — otherwise a module that reported it could not load leaves a ticking netcode and an open link under a node the host is about to free. |

## Teardown is in reverse, and the order is not cosmetic

Services hold a callable the bridge calls; the roster holds subsystems it notifies; the netcode is what everything else attached to. Tearing the netcode down first leaves each of the others calling into a freed object for as long as it takes them to notice, which is never. `_teardown` goes: signals, roster, services, identity, bridge, manager.

`DotGameRoster.clear()` is deliberately **not** "remove everybody". A module being torn down is not a room emptying: the subsystems that would be notified are going away in the same breath, and calling `remove_peer` on a freed one is the crash the ordering exists to avoid.

## `session_fn` exists so the bug above can be asserted

`DotGameRoster.session_fn` is injectable, and the reason is narrow: the bug this addon exists to prevent is reading the **wrong field** off the spawn event, and a test that cannot substitute the lookup cannot distinguish "read the right field" from "found nothing either way" — which is exactly what the two broken games looked like from outside. With it substituted, `examples/game_selftest.gd` can feed in an event carrying only `peer_id`, with a session that a `peer_id` read *would* find, and assert that nobody is seated.

A game with its own session source — a lobby that seats people who never connected — gets the same hook for free.

## Two bugs in dot-server this addon's first suite found

Neither is in this addon, and both had been there for as long as modules have.

**`DotModuleHost.load_module` did not await `_module_load`.** A module's load is allowed to be a coroutine and every non-trivial one is: an identity layer reaches a content host, a profile store, an avatar store. An un-awaited GDScript coroutine returns at its first suspension, which Godot 4.7 reports as *"Trying to call an async function without 'await'"* — and then `result` is null and the next line reads `.ok` off it. It hid because it only fires when a load **actually** suspends: every module in the tree awaited things that happened to finish inside one call — a cloud client with nothing to fetch, a backbone that is not configured — so the coroutine ran to completion and returned like an ordinary function. The first module whose setup really waited was a fixture written to wait on purpose. The consequence in production would have been a server failing to load its game because something it talks to was *slow*.

`_module_unload` is the other half and is deliberately **not** awaited: `unload_all` runs from `_exit_tree`, where there is no frame left to resume a coroutine in. It is enforced instead — the host calls it through `Object.call` (GDScript refuses to take the return value of a `-> void` function) and reports by name any module whose teardown suspended.

**A log line could fail the load it was describing.** `load_module` read `module.describe()["commands"]`, and `describe()` is a method the family expects every stateful object to override. An override that did not happen to keep that key threw *inside the logging call*, after the module was already in `_modules` — so the load returned null and the next attempt said the module was already loaded. It is `.get("commands", 0)` now, and `DotGameModule.describe()` merges `super.describe()` rather than replacing it, which is the rule a subclass should follow anyway.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 200 godot --headless --path . res://examples/game_selftest.tscn   # 60 checks, 9 sections
```

**Adding a `class_name` here breaks every consumer until each is re-imported**, and that is not theoretical: `DotGameServices` was added to this addon and a dedicated server three repositories away spent a boot reporting *"Could not resolve script … bfh_services.gd"* — its own class cache had never heard of the base class. The addon was fine, the game was fine, and the cache was stale. Re-import every project that links this one.

The suite boots a real `DotServer` with a real `DotModuleHost` and loads the fixture module by path, because that is how a game is loaded in production — `load_module` takes a path so an operator can name one in a config file, which means a pre-built instance with its fields already assigned is thrown away and a fresh one made with them null.

**The fixtures suspend on purpose.** `test_identity.setup()` and `test_services.setup()` both await a frame, because every real one reaches a network and a skeleton that only worked with collaborators which happen to finish synchronously would pass a suite and fail on the first deployment. That is precisely what found the `load_module` bug above.

## `DotGameServices`, and why it names none of the three addons it drives

The second extraction, done on 2026-09-14 and measured the same way: five services layers of 557, 559, 635, 716 and 718 lines, differing in their channels, their rules and a voice range. The relay is identical in all five, comments included; so are the admission check, the peer fan-out, the punishment subject, and the ORDER — which is the part with a bug behind it. **Moderation is built first because it publishes `dot_mute_source`, and both routers look that name up when they START.** A chat router built first finds nothing, warns once, and then enforces no gag for the life of the server.

**dot-chat, dot-voice and dot-moderation are NOT dependencies of this addon and must not become them.** A game with no chat is a legitimate game; a game with no voice is most of them. So each layer is loaded BY PATH and driven through `set()` and `call()`, exactly as this module loads dot-platform's — and a missing addon is a layer skipped with a line, not a server that will not boot. What a subclass hands back — channels, rules, a voice config — it may name freely, because a game that configures chat is a game that has dot-chat.

The cost of that is real and worth stating: the base cannot type-check anything it builds. What protects it is that every property it sets is set in one place, and `game_selftest` runs the whole sequence in a project that has **none** of the three — which is the only path this addon can test and the one that has to be quiet and complete. The other half, a line actually crossing a wire and a gag actually silencing somebody, is asserted in `mg-buses-from-hell/examples/headless_net.tscn`.

## The live tools are a fourth layer, and the verbs are the subclass's

`DotGameServices` builds dot-moderation's `DotModTools` straight after the manager — by path, like every layer here — and binds `DotModToolCommands` onto the server's console, so a subclass gets noclip, god, slay, bring and the rest by answering `_mod_abilities()` with a table of callables keyed by plain strings (`"noclip"`), which needs no dot-moderation name either. `_mod_unsupported()` is the reasons for what it refuses, `_mod_can_teleport()` / `_mod_position()` / `_mod_teleport()` the teleport verbs, `_mod_configure_commands()` the last word on `alive_fn` and `team_fn`. The ids are the session userid as a string, and `_mod_session` resolves one.

Two things are the base's rather than the game's, and both have a bug behind them in the obvious alternative:

- **The commands are unbound in `_exit_tree`.** They are registered on the server's console, which outlives this layer; a module unload that left them there hands the next `noclip` to a freed object. mg-buses-from-hell's `dedicated` unloads and reloads the module and asserts the commands leave and come back.
- **`DotGameRoster` calls `forget_player(userid)` on every follower as somebody leaves**, beside `forget_voter`. Who a player was frozen or noclipped by is keyed on a userid, and the next person given that userid must not inherit it.

What a respawn means is the game's, so a subclass calls `mod_player_respawned(id)` from its own spawn path — buses from the start of every round.

## Still to do

- **The five games have not been converted.** This addon was extracted from them and is tested against a fixture and one real game; not one of the five subclasses either base yet. Convert one first — arena is the reference game and the smallest of the five modules — and check `headless_match` still plays a whole deathmatch before touching the others.
- **The identity layer is the last extraction.** 215 and 262 lines in the two that have one, near-identical.

## What uses this

`mg-buses-from-hell`, since 2026-09-14, and it is the first. Its module is **ninety lines** against the five hand-written ones' 837 to 1,816, and its services layer is **sixty** against 557 to 718 — which is the number this addon was extracted to produce, on the one game that never had a copy to migrate. Both were exercised against a real dedicated server, a published pack and a client in a second process before this paragraph was written.
