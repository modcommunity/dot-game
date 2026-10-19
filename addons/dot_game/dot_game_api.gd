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
const LEVEL := 11
const OLDEST := 1
