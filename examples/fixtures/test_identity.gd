extends Node

## An identity layer, reduced to what [DotGameModule] asks of it.
##
## `setup` SUSPENDS on purpose: every real one reaches a network, and a skeleton that only works with a synchronous one would fail on first deployment.

var backbone: Object = null
var setup_calls: int = 0
var refuse: bool = false


func setup() -> DotResult:
	setup_calls += 1
	await get_tree().process_frame

	if refuse:
		return DotResult.fail(DotError.CODE_STATE, "refusing on purpose")

	# Something non-null, so the module's hand-off to the services layer is observable.
	backbone = self
	return DotResult.success(self)
