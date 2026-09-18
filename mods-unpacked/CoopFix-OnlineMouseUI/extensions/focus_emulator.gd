extends "res://ui/menus/global/focus_emulator.gd"


func _ready() -> void:
	add_to_group("coopfix_mouse_emulators")


func _handle_input(event: InputEvent) -> bool:
	# Godot 3 invokes inherited _input callbacks too. Intercept the helpers
	# called by vanilla _input so it neither activates nor consumes mouse input.
	if _is_online_mouse(event):
		return false
	return ._handle_input(event)


func _is_coop_ui_action(event: InputEvent) -> bool:
	if _is_online_mouse(event):
		return true
	return ._is_coop_ui_action(event)


func _is_online_mouse(event: InputEvent) -> bool:
	if not event is InputEventMouse:
		return false
	var router = _mouse_router()
	return router != null and router.is_online()


func _on_focus_changed(control: Control) -> void:
	var router = _mouse_router()
	if router != null and router.is_online():
		if not router.owns_emulator(self):
			return
		if router.dispatch_emulator != null and router.dispatch_emulator != self:
			return
	._on_focus_changed(control)


func _mouse_router():
	return get_node_or_null("/root/ModLoader/CoopFix-OnlineMouseUI/MouseRouter")
