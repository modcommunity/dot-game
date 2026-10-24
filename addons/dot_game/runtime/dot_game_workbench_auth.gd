class_name DotGameWorkbenchAuth
extends RefCounted

## dot-auth accounts for a [DotGameWorkbench]: a connect ticket is accepted as the bearer when its uid is listed in `workbench.admin_uids` / `admin_groups`.
##
## dot-auth and dot-workbench are reached by path and `call`, so a build without either has no account login and no error.

const CHANNEL := "game.workbench"
const IDENTITY_SCRIPT := "res://addons/dot_workbench/dot_workbench_identity.gd"
const TICKET_SCRIPT := "res://addons/dot_auth/server/dot_auth_ticket.gd"
const AUTH_SERVICE := &"dot_auth_server"


## Admits tickets through [param resolver] on [param wb]'s api, beside the actors it already permits. [param admin_permit] is `(uid, flag) -> bool`. Value: the gate, or null when it cannot be built.
static func attach(wb: DotGameWorkbench, resolver: Callable, admin_permit: Callable) -> RefCounted:
	if wb.api == null or not resolver.is_valid() or not ResourceLoader.exists(IDENTITY_SCRIPT):
		return null
	var gate: RefCounted = (load(IDENTITY_SCRIPT) as GDScript).new()
	gate.set("resolver", resolver)
	gate.set("fallback_permit", admin_permit)
	gate.set("admin_uids", PackedStringArray(wb.config.get("admin_uids", [])))
	gate.set("admin_groups", PackedStringArray(wb.config.get("admin_groups", [])))
	var base: Callable = wb.api.get("permit")
	var runtime: Object = wb.api.get("runtime")
	wb.api.set("identity", gate.get("authenticate"))
	wb.api.set("permit", func(actor: Variant, flag: String) -> bool:
		return bool(gate.call("permit", actor, flag)) or (base.is_valid() and bool(base.call(actor, flag))))
	if runtime != null:
		runtime.set("actor_name", func(actor: Variant) -> String: return str(actor))
	return gate


## A resolver that verifies a dot-auth connect ticket offline against the server's key, or an invalid Callable. Sync on purpose (the api hook is); a ticket is short-lived and checked for this server's audience, but not burned.
static func ticket_resolver(auth: Object) -> Callable:
	if auth == null or not ResourceLoader.exists(TICKET_SCRIPT):
		return Callable()
	var cfg: Object = auth.get("config")
	if cfg == null or str(cfg.get("ticket_public_key")).is_empty():
		return Callable()
	# An empty server_id makes verify skip the audience check, so any server's ticket would pass.
	if str(cfg.get("server_id")).strip_edges().is_empty():
		return Callable()
	var key: String = cfg.get("ticket_public_key")
	var sid: String = cfg.get("server_id")
	var leeway: int = int(cfg.get("ticket_leeway_sec"))
	return func(token: String) -> Variant: return identity_of_ticket(token, key, sid, leeway)


## The identity in a verified ticket, or null. A ticket with no expiry is refused: verify only checks `exp` when present.
static func identity_of_ticket(token: String, public_key: String, server_id: String, leeway: int) -> Variant:
	if not ResourceLoader.exists(TICKET_SCRIPT):
		return null
	var res: DotResult = (load(TICKET_SCRIPT) as GDScript).call("verify", token, public_key, server_id, leeway)
	if not res.ok:
		return null
	var who: Object = (res.value as Dictionary).get("identity")
	return who if who != null and int(who.get("expires_at")) > 0 else null
