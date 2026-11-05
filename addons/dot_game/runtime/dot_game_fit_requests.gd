class_name DotGameFitRequests
extends RefCounted
## Remembers `fit_touch_buttons` requests so a screen fit attached later (or again) still sizes them.

const CHANNEL := "dot_game_fit_requests"

var _requests: Array[Dictionary] = []


## Attaches [param current] or a new fit on [param root]; replays the remembered requests onto it. Null when none.
func attach(root: Window, current: DotGameScreenFit) -> DotGameScreenFit:
	if current != null and current.window != null:
		return current
	var fit := DotGameScreenFit.install(root, -1, current)
	if fit == null:
		return null
	for e in _requests:
		var b: Control = e["ref"].get_ref()
		if b != null:
			fit.fit_buttons(b, e["layout"])
	return fit


## Records the request (replacing an earlier one for the same buttons) and applies it when [param fit] is attached; 1 otherwise.
func request(fit: DotGameScreenFit, buttons: Control, layout: Array) -> float:
	_requests = _requests.filter(func(e: Dictionary) -> bool: return e["ref"].get_ref() != null and e["ref"].get_ref() != buttons)
	_requests.append({"ref": weakref(buttons), "layout": layout})
	if fit == null or fit.window == null:
		DotLog.debug(CHANNEL, "no screen fit attached: touch buttons kept at their design size until one is")
		return 1.0
	return fit.fit_buttons(buttons, layout)
