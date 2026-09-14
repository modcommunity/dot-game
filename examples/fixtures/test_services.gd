extends Node

## Chat, voice and moderation, reduced to what [DotGameModule] asks of it.

var backbone: Object = null
var server: DotServer = null
var game: Object = null
var link: Object = null

var peers_added: Array[int] = []
var peers_removed: Array[int] = []
var refuse_admission: bool = false
var setup_calls: int = 0


func setup(p_server: DotServer, p_game: Object, p_link: Object) -> DotResult:
	setup_calls += 1
	server = p_server
	game = p_game
	link = p_link
	await get_tree().process_frame
	return DotResult.success(self)


func relay_voice(_peer: int, _payload: PackedByteArray) -> void:
	pass


func check_admission(_session: DotClientSession) -> DotResult:
	if refuse_admission:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "banned on purpose")
	return DotResult.success(true)


func add_peer(peer_id: int) -> void:
	peers_added.append(peer_id)


func remove_peer(peer_id: int) -> void:
	peers_removed.append(peer_id)
