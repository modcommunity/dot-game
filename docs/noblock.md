# DotGameNoblock: teammates pass through, enemies stop, for every game

dot-team's `DotTeamBlockRules` decides per pair whether two players collide; dot-player-controller's `DotPlayerBodyRules.pair_fn` is where a body asks. `DotGameNoblock` is the wiring between them that every game would otherwise repeat. dot-team is loaded by path and named nowhere, so a build without it runs with players blocking each other and one WARN line.

## Server: nothing to write

`DotGameModule` builds it after `_game_load()` when the game object has a `body_rules` and no `block_rules` of its own. It feeds `body_rules.pair_fn`, sets `game.block_rules` if the game declares it, binds `mp_teamblock`, `mp_enemyblock`, `mp_blockcmd`, `mp_blockcmd_relations`, `mp_blockscope` (REPLICATED, archived) and `mp_blockstate` (REPLICATED, hidden), registers `!block` and `!noblock`, and calls `rules.forget(userid)` when a player leaves. Hooks to override on the module: `_noblock_enabled()` (return false to opt out), `_noblock_side(id)` (default: `str(game.team_of(id))`, empty for team 0), `_noblock_runtime()` (the game's `DotProfileRuntime`, so the workbench lists the kind). The game must still ask `body_rules.blocks(a, b)` wherever it sweeps against other players (dot-player-controller's own controllers do; a hand-written hull list, like a custom movement body, filters on it).

## Client: one call

After `DotGameClient.setup()`: `client.add_noblock(game, Callable(game, "team_of_side"))`, with a `side_fn` returning the same side ids as the server's. It builds the rules, feeds `body_rules.pair_fn` and follows the replicated cvars of `client.link`; it fails loudly when dot-team is absent or the link cannot replicate cvars, because a client that does not follow rubber-bands against the server.

## Config

The config is dot-team's `DotTeamBlockConfig`, run through a `DotGameConfigBinder` with `profile_kind` and `profile_id` both `noblock` (the binder's new `profile_kind` lets a game carry a second profile set beside its `config` one). Layers, weakest first: code defaults, `cfg/game/<game>/noblock/noblock.yml`, `cfg/server/game/<game>/noblock/noblock.yml`, `--profile.noblock/noblock.<key>=`, `DOT_TEAM_BLOCK_*` env, `--team-block-*` argv. Strict on a dedicated server: an unknown key or bad value makes the module refuse to load. The cvars start at the config's values; a cvar edit changes the config, and a workbench edit of the `noblock` kind writes the cvar. A yml file is a flat mapping, for example `team_block: true`.

Test: `examples/headless_noblock.tscn`; the module wiring is a section of `examples/game_selftest.tscn` (the dot-team half only runs when the addon is linked).
