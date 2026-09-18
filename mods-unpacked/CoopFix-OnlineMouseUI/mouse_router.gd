extends Node

# Reuse the game's FocusEmulator and Online's existing button intercepts. No
# gameplay or network action is reproduced here: only physical mouse input.
var dispatch_emulator = null
var _api = null
var _adapter = null
var _configure_elapsed = 0.0
var _pressed_button = null
var _pressed_emulator = null
var _popup_emulator = null
var _popup_press_started = false
var _click_serial = 0
var _drag_control = null
var _drag_emulator = null


func _ready() -> void:
	pause_mode = Node.PAUSE_MODE_PROCESS
	_adapter = load(get_script().resource_path.get_base_dir().plus_file("ui_adapter.gd")).new()
	add_child(_adapter)


func is_online() -> bool:
	if not is_instance_valid(_api):
		var apis = get_tree().get_nodes_in_group("brotato_online_api")
		_api = apis[0] if not apis.empty() else null
	return is_instance_valid(_api) and _api.is_online()


func owns_emulator(emulator) -> bool:
	return is_instance_valid(emulator) and emulator.is_processing_input() and _api.owns_player(int(emulator.player_index))


func _process(delta: float) -> void:
	if not is_online():
		_cancel_press()
		return
	if _native_overlay_active():
		_cancel_press()
		return
	_configure_elapsed += delta
	if _configure_elapsed >= 0.15:
		_configure_elapsed = 0.0
		_adapter.configure_scene(get_tree().current_scene, _api)
		for emulator in get_tree().get_nodes_in_group("coopfix_mouse_emulators"):
			if owns_emulator(emulator) and _has_visible_base(emulator):
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				break


func _input(event: InputEvent) -> void:
	if not event is InputEventMouse or not is_online():
		return
	if event.control or _native_overlay_active():
		_cancel_press()
		return
	var emulators = []
	var has_visible_ui = false
	for emulator in get_tree().get_nodes_in_group("coopfix_mouse_emulators"):
		var visible_base = _has_visible_base(emulator)
		has_visible_ui = has_visible_ui or visible_base
		if owns_emulator(emulator) and visible_base:
			# Shared character inventory belongs to the local keyboard slot first;
			# individual panels still match only their own emulator's base.
			if int(emulator._device) == 0:
				emulators.push_front(emulator)
			else:
				emulators.append(emulator)
	if emulators.empty() and not has_visible_ui:
		_cancel_press()
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if is_instance_valid(_drag_control) and owns_emulator(_drag_emulator):
		FocusEmulatorSignal.set_expected_control(_drag_control, int(_drag_emulator.player_index))
		if event is InputEventMouseButton and not event.pressed and event.button_index == BUTTON_LEFT:
			_drag_control = null
			_drag_emulator = null
		return
	# Wheel events keep the engine's native ScrollContainer behavior.
	if event is InputEventMouseButton and event.button_index != BUTTON_LEFT:
		return
	var modal = get_viewport().get_modal_stack_top()
	if modal is PopupMenu:
		# Keyboard can open an OptionButton before the mouse selects its item.
		if not owns_emulator(_popup_emulator) or _popup_emulator._find_control_base_data(modal) == null:
			_popup_emulator = null
			for emulator in emulators:
				if emulator._find_control_base_data(modal) != null:
					_popup_emulator = emulator
					break
		if _popup_emulator != null:
			FocusEmulatorSignal.set_expected_control(modal, int(_popup_emulator.player_index))
			if event is InputEventMouseMotion:
				# A popup can extend beyond its parent's scroll clipping. Feed the
				# original native hit detector its local mouse coordinates directly.
				var local_motion = event.duplicate()
				local_motion.position = modal.get_global_transform_with_canvas().affine_inverse().xform(event.position)
				modal._gui_input(local_motion)
				get_tree().set_input_as_handled()
			elif event is InputEventMouseButton:
				get_tree().set_input_as_handled()
				if event.pressed:
					_popup_press_started = _contains(modal, event.position)
					if not _popup_press_started:
						modal.hide()
				else:
					var index = modal.get_current_index()
					if _popup_press_started and _contains(modal, event.position) and index >= 0 and not modal.is_item_disabled(index) and not modal.is_item_separator(index):
						# Keep native hover hit detection; reuse FE's popup accept/signals.
						_activate(modal.get_parent(), _popup_emulator)
					_popup_press_started = false
		elif event is InputEventMouseMotion or (event is InputEventMouseButton and event.button_index == BUTTON_LEFT):
			get_tree().set_input_as_handled()
		return
	_popup_press_started = false
	# Popup instances maintain their own native modal mouse handling.
	if modal != null:
		return
	if is_instance_valid(Utils._popup) and Utils._popup.is_visible_in_tree():
		return
	var root = _input_root()
	var hit = _hit_test(root, event.position, emulators)
	if not hit.empty() and hit[1] == null:
		hit = []
	if not hit.empty() and (hit[0] is Slider or hit[0] is ScrollBar):
		_focus(hit[0], hit[1])
		FocusEmulatorSignal.set_expected_control(hit[0], int(hit[1].player_index))
		if event is InputEventMouseButton and event.pressed:
			_drag_control = hit[0]
			_drag_emulator = hit[1]
		return
	if event is InputEventMouseMotion:
		if not hit.empty() and not _keep_ready_focus(hit[1]):
			_focus(hit[0], hit[1])
		get_tree().set_input_as_handled()
		return
	if not event is InputEventMouseButton:
		return
	# Consume misses too: another machine's buttons must never receive a native
	# click lacking the owning player's FocusEmulatorSignal context.
	get_tree().set_input_as_handled()
	if event.pressed:
		_cancel_press()
		if hit.empty():
			return
		var button = hit[0]
		var emulator = hit[1]
		_focus(button, emulator)
		_pressed_button = button
		_pressed_emulator = emulator
		_emit(button, "button_down", emulator)
		if _usable(button) and button.action_mode == BaseButton.ACTION_MODE_BUTTON_PRESS:
			_activate(button, emulator)
	else:
		var button = _pressed_button
		var emulator = _pressed_emulator
		_pressed_button = null
		_pressed_emulator = null
		if not is_instance_valid(button) or not owns_emulator(emulator):
			return
		if _usable(button) and not hit.empty() and hit[0] == button and button.action_mode == BaseButton.ACTION_MODE_BUTTON_RELEASE:
			_activate(button, emulator)
		_emit(button, "button_up", emulator)


func _input_root():
	var scene = get_tree().current_scene
	if scene == null:
		return null
	for path in ["UI/PauseMenu", "PauseMenu"]:
		var pause_menu = scene.get_node_or_null(path)
		if pause_menu != null and pause_menu.is_visible_in_tree():
			return pause_menu
	var popup = _focused_item_popup(scene)
	return popup if popup != null else scene


func _native_overlay_active() -> bool:
	# Online's overlays live outside current_scene. Its player list does not
	# suspend the real PauseMenu emulator, so preserve native overlay input here.
	var online = _api.get_parent()
	var player_list = online.get_node_or_null("BrotatoOnlinePlayerListOverlay")
	if player_list != null and bool(player_list.get("_overlay_open")):
		return true
	# QuickChat retains a visible, empty overlay root after closing its wheel.
	var quick_chat = online.get_node_or_null("BrotatoOnlineQuickChatWheel")
	if quick_chat != null and bool(quick_chat.get("_wheel_active")):
		return true
	var scene = get_tree().current_scene
	var settings = scene.get_node_or_null("BrotatoOnlineSettingsOverlay") if scene != null else null
	return settings != null and settings.is_visible_in_tree()


func _keep_ready_focus(emulator) -> bool:
	var scene = get_tree().current_scene
	if scene == null or not scene.has_method("_get_go_button"):
		return false
	var index = int(emulator.player_index)
	var ready = scene.get("_player_pressed_go_button")
	return ready != null and index >= 0 and index < ready.size() and bool(ready[index]) and emulator.focused_control == scene._get_go_button(index)


func _focused_item_popup(node):
	if node is ItemPopup and node.is_visible_in_tree() and node._focused and _api.owns_player(int(node.player_index)):
		return node
	for child in node.get_children():
		var popup = _focused_item_popup(child)
		if popup != null:
			return popup
	return null


func _has_visible_base(emulator) -> bool:
	for base in emulator._focus_base_nodes:
		if is_instance_valid(base) and base is CanvasItem and base.is_visible_in_tree():
			return true
	return false


func _usable(button) -> bool:
	return is_instance_valid(button) and not button.is_queued_for_deletion() and button.is_visible_in_tree() and not button.disabled and button.focus_mode != Control.FOCUS_NONE


func _hit_test(node, position: Vector2, emulators: Array) -> Array:
	if node == null or node is Viewport:
		return []
	if node is CanvasItem and not node.is_visible_in_tree():
		return []
	if node is Control and node.rect_clip_content and not _contains(node, position):
		return []
	var children = node.get_children()
	children.invert()
	for child in children:
		var hit = _hit_test(child, position, emulators)
		if not hit.empty():
			return hit
	if node is BaseButton and _contains(node, position):
		if not _usable(node):
			return [node, null]
		for emulator in emulators:
			if emulator._find_control_base_data(node) != null:
				return [node, emulator]
		return [node, null]
	if (node is Slider or node is ScrollBar) and _contains(node, position):
		for emulator in emulators:
			if emulator._find_control_base_data(node) != null:
				return [node, emulator]
		return [node, null]
	return []


func _contains(control: Control, position: Vector2) -> bool:
	var local = control.get_global_transform_with_canvas().affine_inverse().xform(position)
	return Rect2(Vector2.ZERO, control.rect_size).has_point(local)


func _focus(button: Control, emulator) -> void:
	dispatch_emulator = emulator
	emulator._set_focused_control_with_style(button, true)
	emulator._ensure_control_visible(button)
	dispatch_emulator = null


func _emit(button, signal_name: String, emulator, argument = null) -> void:
	if not is_instance_valid(button) or not is_instance_valid(emulator):
		return
	dispatch_emulator = emulator
	FocusEmulatorSignal.emit(button, signal_name, int(emulator.player_index), argument)
	dispatch_emulator = null


func _activate(button: BaseButton, emulator) -> void:
	var scene = get_tree().current_scene
	if button is InventoryElement and button.item != null and not button.is_random and scene != null and scene.filename == "res://ui/menus/run/weapon_selection.tscn" and not _api.is_host():
		# An unpatched host applies remote focus deferred. Wait for its existing
		# focus acknowledgement before sending the existing weapon accept action.
		var serial = _click_serial
		var menu_sync = _api._get_menu_sync_manager()
		var item_hash = str(button.item.my_id_hash)
		var player_index = int(emulator.player_index)
		while not _host_has_weapon_focus(menu_sync, player_index, item_hash):
			if not is_online() or get_tree().current_scene != scene or serial != _click_serial or not owns_emulator(emulator) or not _usable(button) or emulator.focused_control != button:
				return
			yield(get_tree(), "idle_frame")
		if not is_online() or get_tree().current_scene != scene or serial != _click_serial or not owns_emulator(emulator) or not _usable(button) or emulator.focused_control != button:
			return
	dispatch_emulator = emulator
	if button is OptionButton:
		_popup_emulator = emulator
	# The existing accept handler supplies toggle/group/OptionButton semantics,
	# including Online's focus hooks, rather than implementing them a second time.
	var accept = InputEventAction.new()
	accept.action = "ui_accept_%s" % emulator._device
	accept.pressed = true
	emulator._handle_input(accept)
	dispatch_emulator = null


func _host_has_weapon_focus(menu_sync, player_index: int, item_hash: String) -> bool:
	if not is_instance_valid(menu_sync):
		return false
	var state = menu_sync.get("_last_state_from_host")
	if str(state.get("screen", "")) != "weapon_selection":
		return false
	for player in state.get("players", []):
		if int(player.get("player_index", -1)) == player_index:
			return str(player.get("focus", {}).get("id_hash", "")) == item_hash
	return false


func _cancel_press() -> void:
	_click_serial += 1
	_popup_press_started = false
	if is_instance_valid(_pressed_button) and is_instance_valid(_pressed_emulator):
		_emit(_pressed_button, "button_up", _pressed_emulator)
	_pressed_button = null
	_pressed_emulator = null
	_drag_control = null
	_drag_emulator = null
