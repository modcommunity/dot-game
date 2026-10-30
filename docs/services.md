# DotGameServices, and the hooks

The second extraction: five services layers of 557 to 718 lines, differing in their channels, their rules and a voice range. The relay was identical in all five, comments included; so were the admission check, the peer fan-out, the punishment subject, and the ORDER, which is the part with a bug behind it.

## Moderation first

**Moderation is built first because it publishes `dot_mute_source`, and both routers look that name up when they START.** A chat router built first finds nothing, warns once, and then enforces no gag for the life of the server.

## Why it names none of the three addons it drives

**dot-chat, dot-voice and dot-moderation are NOT dependencies of this addon and must not become them.** A game with no chat is a legitimate game; a game with no voice is most of them. So each layer is loaded BY PATH and driven through `set()` and `call()`, exactly as this module loads dot-platform's, and a missing addon is a layer skipped with a line, not a server that will not boot. What a subclass hands back (channels, rules, a voice config) it may name freely, because a game that configures chat is a game that has dot-chat.

The cost is real: the base cannot type-check anything it builds. What protects it is that every property it sets is set in one place, and `game_selftest` runs the whole sequence in a project that has **none** of the three. The other half, a line actually crossing a wire and a gag actually silencing somebody, is asserted in mg-buses-from-hell's `examples/headless_net.tscn`.

## The live tools are a fourth layer, and the verbs are the subclass's

`DotGameServices` builds dot-moderation's `DotModTools` straight after the manager (by path, like every layer here) and binds `DotModToolCommands` onto the server's console, so a subclass gets noclip, god, slay, bring and the rest by answering `_mod_abilities()` with a table of callables keyed by plain strings (`"noclip"`), which needs no dot-moderation name either. `_mod_unsupported()` is the reasons for what it refuses, `_mod_can_teleport()` / `_mod_position()` / `_mod_teleport()` the teleport verbs, `_mod_configure_commands()` the last word on `alive_fn` and `team_fn`. The ids are the session userid as a string, and `_mod_session` resolves one.

Two things are the base's rather than the game's, and both have a bug behind them in the obvious alternative:

- **The commands are unbound in `_exit_tree`.** They are registered on the server's console, which outlives this layer; a module unload that left them there hands the next `noclip` to a freed object.
- **`DotGameRoster` calls `forget_player(userid)` on every follower as somebody leaves**, beside `forget_voter`. Who a player was frozen or noclipped by is keyed on a userid, and the next person given that userid must not inherit it.

What a respawn means is the game's, so a subclass calls `mod_player_respawned(id)` from its own spawn path.

## The hooks the first converted game needed

The first hand-written game moved onto both bases (a 2D lobby, since scratched) found five places the base had no question to ask, each worked round in its subclass. They are hooks now, each with a default that is exactly the old behaviour:

| Hook | Default | What it replaced |
| --- | --- | --- |
| `DotGameServices.setup(null, …)` | allowed; only what is bound to a server is skipped (the tool commands, the relay's "tell the clients", the admin and audit seams, each already answered "no server") | a copy of the whole sequence minus the one guard that refused a null server: the duplication this addon exists to end |
| `_can_hear(listener, speaker, listener_at, speaker_at) -> bool` | `true`, wired into both routers' `can_hear_fn` | setting `can_hear_fn` on chat and voice after `super.setup` |
| `_mod_configure_tools(tools)` | nothing; called after the handlers and refusals, before the tools enter the tree or a command is bound | a `_build_mod_tools` override calling `super` and then setting `goto_standoff` and `persist_on_respawn` |
| `_peer_can_receive(peer_id) -> bool`, and `send_backlog(peer_id)` | `true`: `add_peer` sends the backlog at seating | an `add_peer` override that dropped the backlog, because a client that builds its scene after it is seated turns a line sent then into a "Node not found" |
| `DotGameModule._can_tick() -> bool` | `true` | a `_physics_process` override that skipped the tick while a game change had freed the world |

`_can_hear` is asked only of listeners already inside a proximity channel's range, so the default costs one call per such listener and nothing elsewhere.

## Hibernation

After `_game_load`, `_follow_hibernation()` searches the module's subtree for anything answering `follow_hibernation(server)` (dot-vote's `DotVoteDirector`, dot-map's `DotMapSession`, found by the method and named nowhere), hands it the server, then calls `_game_hibernation(hibernating)` on every `hibernation_changed`. Every game here builds its vote under its module, so a game on this base gets "the map clock waits while the server is empty and starts again from the top when somebody joins" without a line; a clock that is the game's own rule (a ballot timer, a round) is reset in `_game_hibernation(false)`. The teardown disconnects it.

## Stats sessions

`DotGameModule.stats_feed` (`DotGameStatsFeed`) listens to the roster's `seated` and `unseated` signals and calls `begin(key, name, {is_bot, map})` and `end(key)` on a dot-stats tracker, set as `stats_feed.tracker` or registered as the service `dot_stats_tracker`. Duck-typed: no tracker, nothing happens. A bot is a `local` session (no transport peer), which is how dot-bot's players are seated; a seat never carries a `tmc_user`. The key is `key_for(session)`, stable across reconnects and restarts and different on every server: dot-platform's profile key, else the backbone's issued `scoped_key` claim, else a dot-user `DotUserScope` HMAC of `session.uid()` (members and `guest:<device>` guests alike) under a key generated once into `scope_key_file` (`user://stats_scope.key`; back it up, losing it renames every player). A bot or a session with no identity keeps `u<userid>`; never an account id, so dot-stats' reporter refusal of `backbone:` ids never fires. Two seats on one uid at once (two guests on one device, a reconnect before the old seat times out) get `<key>-<userid>` for the second. dot-user is loaded by path. A game that drives its own tracker sets `open_sessions = false` and asks `key_for` (or holds its own `DotGameStatsFeed` and calls `forget(userid)` on leave); `player_key_fn` replaces the lot. **A key is cached at the first ask and never changes by itself**, so a game's stats do not split mid-session; if the profile key arrives later (a late admission, `player_admitted` after the seat), the guest-derived key stays until the game calls `upgrade(session)`, which moves the seat to the profile or issued key and, for an open session, ends it under the old key and begins it under the new. The old key's row is not merged.
