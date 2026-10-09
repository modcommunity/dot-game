extends RefCounted

## dot-game's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: everything before this file existed (an absent file reads as 1).
# 2: DotGameModule _game_board_fields() and _game_board_extra(), the Tab board's columns.
# 3: DotGameChatClient, the client's chat box and microphone.
const LEVEL := 3
const OLDEST := 1
