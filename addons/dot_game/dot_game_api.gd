extends RefCounted

## dot-game's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: everything before this file existed (an absent file reads as 1).
# 2: DotGameModule _game_board_fields() and _game_board_extra(), the Tab board's columns.
# 3: DotGameChatClient, the client's chat box and microphone.
# 4: DotGameContent, the map packs a server names for the running game.
# 5: DotGameChatClient draws dot-server's own lines (server_lines, server_colour, link),
#    window_settings, voice_method.
# 6: DotGameChatClient honours the player's block list (self_mute, self_mute_enabled).
# 7: voice: DotGameChatClient opens the microphone on the first press of dot-voice's
#    dot_voice_talk action (not on attach), follows the replicated sv_voice_enable, publishes
#    its manager as dot_voice_client, voice_available_changed, voice_position_fn; DotGameModule
#    binds sv_voice_enable and sv_voice_mode on the services' router.
# 8: DotGameClient, the platform layer a game client adds: load gate and cover, settings and
#    the Escape menu, console, HUD theme, Tab, M, the chat's keyboard, the pointer, web sync.
# 9: still loading. DotGameModule is_loading / is_peer_loading / can_be_harmed /
#    can_peer_be_harmed / loading_seats / mark_reloading, loading_changed, load_timeout_sec,
#    reload_grace_sec, report_map re-marks on a new map, the game's peer_loading_fn;
#    DotGameRoster's loading state and COVER_KIND; DotGameClient report_loading and the
#    static report_cover.
# 10: DotGameLink.attach / retire, a game's RPC link under the server node, freed with its bridge.
# 11: DotGameClient set_hud / set_chat (after setup), cover_scene / cover (the gate's cover),
#    pointer_fn (when the pointer is taken back), public refresh_blocked().
# 12: DotGameClient adopts a menu and board the game built (menu / board / board_prepare_fn /
#    adopt_menu, no settings needed), add_console(), gate_only, escape_releases_pointer.
# 13: DotGameClient user_cfg / listen_host_fn / user_cfg_files / open_user_cfg, the player's cfg tier
#    for solo and listen-host play, and the editor entry on the Advanced page.
# 14: DotGameClient look-to-gag and look-to-mute (use_look_mute, look_*_action, look_positions_fn,
#    look_target_fn, look_chat_mute_fn, look_mute, look_conflicts), on G and K, default on.
# 15: DotGameClient.restore_map_config, also run when the server connection drops (not only on EXIT_TREE).
# 16: DotGameMapScripts, the handler for dot-map's script.* events; DotGameModule.map_scripts.
# 17: DotGameConfigBinder / DotGameConfigSchema, a DotConfig as layered load, cvars, `config` profile and yml diff.
# 18: DotGameWorkbench and DotGameClient.add_workbench, the F9 tuning window.
# 19: DotGameNoblock, built by DotGameModule for a game with body_rules (_noblock_enabled / _noblock_side /
#    _noblock_runtime, noblock), DotGameClient.add_noblock, DotGameConfigBinder.profile_kind.
# 20: DotGameWorkbenchAuth, and DotGameWorkbench accounts / account_resolver / account_permit_fn / account_gate: dot-auth
#    tickets admitted by default (admin_uids, admin_groups).
# 21: DotGameAvatarActionMessage / Relay / Client, DotGameClient.add_avatar_actions, DotGameModule._avatar_actions_equipped and _avatar_action_veto.
const LEVEL := 21
const OLDEST := 1
