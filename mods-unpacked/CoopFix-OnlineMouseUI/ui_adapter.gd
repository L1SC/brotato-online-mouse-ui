extends Node

# Cooperation hides these existing mouse buttons in favor of controller hints.
# Keep Online's signals, ownership and authoritative disabled state untouched.
var _lock_icon = load("res://items/global/locked_icon.png")
var _ban_icon = load("res://items/global/baned_item.png")


func configure_scene(scene: Node, api: Node) -> void:
	if scene == null or api == null or not api.is_online():
		return
	_configure_reward_buttons(scene, api)
	if not scene.has_method("_get_coop_player_container"):
		return
	for value in api.get_local_player_indices():
		var player_index = int(value)
		if player_index < 0 or player_index >= RunData.get_player_count():
			continue
		var container = scene._get_shop_items_container(player_index)
		if container == null:
			continue
		for shop_item in container._shop_items:
			if not is_instance_valid(shop_item) or not api.owns_player(int(shop_item.player_index)):
				continue
			var lock_button = shop_item._lock_button
			var ban_button = shop_item._ban_button
			var lockable = shop_item.item_data != null and shop_item.item_data.is_lockable
			_configure_button(lock_button, bool(shop_item.active) and lockable, _lock_icon, tr("MENU_LOCK"))
			var ban_text = ban_button.text if ban_button != null and ban_button.text != "" else tr("MENU_BAN")
			_configure_button(ban_button, bool(shop_item.active), _ban_icon, ban_text)


func _configure_reward_buttons(scene: Node, api: Node) -> void:
	var ui = scene.get_node_or_null("UI/CoopUpgradesUI")
	if ui == null or not ui.is_visible_in_tree():
		return
	for value in api.get_local_player_indices():
		var container = ui._get_player_container(int(value))
		if not is_instance_valid(container):
			continue
		var button = container._ban_button
		# Online's client intercept connects pressed but omits the release handler.
		# Reuse the original cancellation method so a short press really cancels.
		if is_instance_valid(button) and not button.is_connected("button_up", container, "_on_BanButton_button_up"):
			button.connect("button_up", container, "_on_BanButton_button_up")


func _configure_button(button, allowed: bool, icon, tooltip: String) -> void:
	if not is_instance_valid(button):
		return
	if not allowed or button.disabled:
		if button.has_meta("coopfix_mouse_button"):
			button.hide()
			button.focus_mode = Control.FOCUS_NONE
		return
	button.set_meta("coopfix_mouse_button", true)
	# Compact icons fit the original horizontal product row even with four slots.
	# No new action controls are created and no product/pricing data is modified.
	if button.text != "" or button.hint_tooltip == "":
		button.hint_tooltip = tooltip
	button.text = ""
	button.icon = icon
	button.expand_icon = true
	button.icon_align = Button.ALIGN_CENTER
	button.rect_min_size = Vector2(34, 34)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_ALL
	button.show()
