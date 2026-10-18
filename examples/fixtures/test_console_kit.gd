extends RefCounted

## A stand-in for dot-console's DotConsoleKit: the one static DotGameClient calls by path.


static func build(host: Node, settings: Object = null, menu: Object = null) -> Node:
	var console := Node.new()
	console.name = "Console"
	console.set_meta(&"settings", settings)
	console.set_meta(&"menu", menu)
	host.add_child(console)
	return console
