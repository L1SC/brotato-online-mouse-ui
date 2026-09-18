extends SceneTree

# Setup uses the installed Online LAN API. Every operation under test enters
# through Input.parse_input_event, with real mouse motion/down/up events.
const ONLINE_PATH = "ModLoader/six666-BrotatoOnline"
const PATCH_PATH = "ModLoader/CoopFix-OnlineMouseUI"

var _role = ""
var _output = ""
var _phase = "full"
var _expect_patch = false
var _baseline = false
var _player_count = 2
var _timeout = 145000
var _started = 0
var _done = false
var _online = null
var _session = null
var _api = null
var _run_data = null
var _menu = null
var _index = -1
var _press_counts = {}
var _host_state = []
var _overlay_mouse_downs = 0
var _weapon_flags_observed = ""
var _result = {"checks": 0, "failures": [], "stages": [], "clicks": []}


func _init() -> void:
	_started = OS.get_ticks_msec()
	for arg in OS.get_cmdline_args():
		var value = arg.substr(arg.find("=") + 1)
		if arg.begins_with("--mouse-test-role="):
			_role = value
		elif arg.begins_with("--mouse-test-output="):
			_output = value
		elif arg.begins_with("--mouse-test-patch="):
			_expect_patch = value == "installed"
		elif arg.begins_with("--mouse-test-baseline="):
			_baseline = value == "yes"
		elif arg.begins_with("--mouse-test-phase="):
			_phase = value
		elif arg.begins_with("--mouse-test-players="):
			_player_count = int(value)
		elif arg.begins_with("--mouse-test-timeout="):
			_timeout = int(value)
	_result["role"] = _role
	call_deferred("_run")


func _idle(_delta: float) -> bool:
	if not _done and current_scene != null and current_scene.filename == "res://ui/menus/run/weapon_selection.tscn":
		var flags = str(current_scene.get("_has_player_selected"))
		if flags != _weapon_flags_observed:
			_weapon_flags_observed = flags
			_record_selection_event("flags", null)
	if not _done and OS.get_ticks_msec() - _started >= _timeout:
		_check(false, "test timeout at " + str(_result["stages"]))
		_finish()
	return false


func _check(condition: bool, message: String) -> bool:
	_result["checks"] += 1
	if not condition:
		_result["failures"].append(message)
		printerr("MOUSE_TEST_FAIL: ", message)
	return condition


func _stage(name: String) -> void:
	_result["stages"].append({"name": name, "elapsed_msec": OS.get_ticks_msec() - _started})
	print("MOUSE_TEST_STAGE=", _role, ":", name)


func _barrier(name: String):
	yield(self, "idle_frame")
	var file = File.new()
	_check(file.open(_output.get_base_dir().plus_file(_role + "." + name), File.WRITE) == OK, "write isolated test barrier")
	file.store_string("ready")
	file.close()
	var roles = ["host"]
	for index in range(1, _player_count):
		roles.append("client" + str(index))
	var deadline = OS.get_ticks_msec() + 20000
	while not _done:
		var ready = true
		for role in roles:
			ready = ready and file.file_exists(_output.get_base_dir().plus_file(role + "." + name))
		if ready:
			break
		if OS.get_ticks_msec() >= deadline:
			_check(false, "barrier " + name + " timed out waiting for all peers")
			_finish()
			return
		yield(create_timer(0.05), "timeout")
	# Observe authoritative state after every peer's injected input has reached
	# Online's normal action queue. Client mirrors intentionally omit some fields
	# between progression screens; the shared snapshot only observes Host state.
	var state_path = _output.get_base_dir().plus_file("host." + name + ".state.json")
	if _role == "host" and not _done:
		yield(create_timer(0.25), "timeout")
		var players = []
		for index in range(_player_count):
			var data = _run_data.get("players_data")[index]
			var item_ids = []
			for item in _run_data.call("get_player_items", index):
				item_ids.append(item.get("my_id_hash"))
			players.append({"gold": int(_run_data.call("get_player_gold", index)), "item_count": item_ids.size(), "weapon_count": _run_data.call("get_player_weapons", index).size(), "item_ids": item_ids, "tokens": int(data.get("remaining_ban_token")), "banned_ids": data.get("banned_items").duplicate(), "locked_count": _run_data.call("get_player_locked_shop_items", index).size(), "effects_hash": JSON.print(data.get("effects")).hash()})
		# Publish atomically: another process must not parse a partially written
		# JSON document merely because its final filename already exists.
		_check(file.open(state_path + ".tmp", File.WRITE) == OK, "write isolated authoritative observation")
		file.store_string(JSON.print(players))
		file.close()
		_check(Directory.new().rename(state_path + ".tmp", state_path) == OK, "publish isolated authoritative observation")
	while not _done and not file.file_exists(state_path):
		if OS.get_ticks_msec() >= deadline:
			_check(false, "barrier " + name + " timed out waiting for Host observation")
			_finish()
			return
		yield(create_timer(0.05), "timeout")
	if not _done:
		_check(file.open(state_path, File.READ) == OK, "read isolated authoritative observation")
		_host_state = JSON.parse(file.get_as_text()).result
		file.close()
		_check(typeof(_host_state) == TYPE_ARRAY and _host_state.size() == _player_count, "complete authoritative observation for " + name)
		var ack = _output.get_base_dir().plus_file(_role + "." + name + ".observed")
		file.open(ack, File.WRITE)
		file.store_string("observed")
		file.close()
		# Keep the next input operation behind this barrier until every peer has
		# read the same frozen observation, including the final wave barrier.
		while not _done:
			var observed = true
			for role in roles:
				observed = observed and file.file_exists(_output.get_base_dir().plus_file(role + "." + name + ".observed"))
			if observed:
				break
			if OS.get_ticks_msec() >= deadline:
				_check(false, "barrier " + name + " timed out waiting for observation acknowledgments")
				_finish()
				return
			yield(create_timer(0.05), "timeout")


func _host_player(index: int = -1) -> Dictionary:
	return _host_state[_index if index < 0 else index]


func _run() -> void:
	yield(self, "idle_frame")
	_result["user_dir"] = OS.get_user_data_dir()
	if not _check(str(ProjectSettings.get_setting("application/config/name")).begins_with("BrotatoMouseUITests-") and "BrotatoMouseUITests-" in OS.get_user_data_dir(), "isolated project and saves"):
		_finish()
		return
	_online = get_root().get_node_or_null(ONLINE_PATH)
	if not _check(_online != null, "real prerequisite Online 6.6.6 ZIP loaded"):
		_finish()
		return
	_result["patch_installed"] = get_root().has_node(PATCH_PATH)
	_check(_result["patch_installed"] == _expect_patch, "patch presence matches local ZIP installation")
	_session = _online.get_node("BrotatoOnlineSessionManager")
	_api = _online.get_node("BrotatoOnlineAPI")
	var steam = _online.get_node("BrotatoOnlineSteamTransport")
	steam.set("_steam", null)
	steam.set("_ready", false)
	_session.set("_steam", null)
	_session.set("_steam_ready", false)
	_run_data = get_root().get_node("RunData")
	_menu = get_root().get_node("MenuData")
	_run_data.call("reset")
	_run_data.set("invulnerable", true)
	var progress = get_root().get_node("ProgressData")
	progress.get("settings")["holding_button"] = false
	progress.get("settings")["ban_mode_toggled"] = true
	progress.get("challenges_completed").append(get_root().get_node("ChallengeService").get("chal_banned_items_hash"))
	_run_data.set("is_ban_mode_active", true)
	if _role == "host":
		change_scene(str(_menu.get("character_selection_scene")))
		yield(create_timer(0.3), "timeout")
		_session.call("create_session", false)
	else:
		change_scene(str(_menu.get("title_screen_scene")))
		yield(create_timer(0.8), "timeout")
		_session.call("join_lan", "127.0.0.1", 27462)
	while not _done and (not bool(_session.call("has_active_online_session")) or int(_session.call("get_session_member_count")) < _player_count or _api.call("get_local_player_indices").size() != 1 or current_scene == null or current_scene.filename != str(_menu.get("character_selection_scene"))):
		yield(create_timer(0.1), "timeout")
	if _done:
		return
	_result["session_id"] = str(_session.call("get_session_id"))
	_result["local_player_indices"] = _api.call("get_local_player_indices")
	_index = int(_result["local_player_indices"][0])
	_result["viewport_rect"] = str(get_root().get_visible_rect())
	_result["viewport_final_transform"] = str(get_root().get_final_transform())
	print("MOUSE_TEST_VIEWPORT=", get_root().get_visible_rect(), " final=", get_root().get_final_transform())
	_check(bool(_session.call("is_game_host")) == (_role == "host"), "actual LAN role")
	_stage("lan_connected")
	yield(create_timer(0.6), "timeout")
	yield(_barrier("character-ready"), "completed")
	var element = _selection_element(0, "well_rounded")
	if not _check(element != null, "real well-rounded character button"):
		_finish()
		return
	_watch(element, "character")
	yield(_click(element, "character"), "completed")
	if _baseline:
		_check(not bool(current_scene.get("_has_player_selected")[_index]), "baseline mouse click does not select the local character")
		if _role == "host":
			_check(int(_press_counts.get("character", 0)) == 0, "baseline host co-op mouse pressed signal blocked")
		yield(_barrier("baseline-finished"), "completed")
		_finish()
		return
	if _expect_patch:
		_check(int(_press_counts.get("character", 0)) == 1, "one character click emits exactly one original pressed signal")
	else:
		# Mixed-install peers use original keyboard input to progress the same game.
		yield(_key(KEY_ENTER), "completed")
	yield(_wait_scene(str(_menu.get("weapon_selection_scene"))), "completed")
	if _done:
		return
	_stage("weapon_selection")
	yield(create_timer(0.6), "timeout")
	yield(_barrier("weapon-ready"), "completed")
	var remote = (_index + 1) % _player_count
	var remote_element = _selection_element(remote, "")
	if _check(remote_element != null, "real remote weapon button"):
		_watch(remote_element, "remote-weapon")
		_watch_weapon_hover(remote_element)
		yield(_click(remote_element, "remote-weapon"), "completed")
		_check(int(_press_counts.get("remote-weapon", 0)) == 0, "mouse cannot emit a remote weapon pressed signal")
		_check(not bool(current_scene.get("_has_player_selected")[remote]), "mouse cannot select a remote weapon slot")
	yield(_barrier("remote-weapon-tested"), "completed")
	element = _selection_element(_index, "")
	if not _check(element != null, "real locally owned weapon button"):
		_finish()
		return
	_watch(element, "weapon")
	_watch_weapon_hover(element)
	yield(_click(element, "weapon"), "completed")
	if not _expect_patch:
		yield(_key(KEY_ENTER), "completed")
	yield(_wait_scene(str(_menu.get("difficulty_selection_scene"))), "completed")
	if _done:
		return
	if _expect_patch:
		_check(int(_press_counts.get("weapon", 0)) == 1, "one weapon click emits exactly one original pressed signal")
	_stage("difficulty_selection")
	yield(create_timer(0.6), "timeout")
	if _role != "host":
		element = _selection_element(0, "")
		if element != null:
			_watch(element, "client-difficulty")
			yield(_click(element, "client-difficulty"), "completed")
			_check(int(_press_counts.get("client-difficulty", 0)) == 0, "client mouse cannot start host-only difficulty")
	yield(_barrier("difficulty-ready"), "completed")
	if _role == "host":
		element = _selection_element(0, "")
		_watch(element, "difficulty")
		yield(_click(element, "difficulty"), "completed")
		if _expect_patch:
			_check(int(_press_counts.get("difficulty", 0)) == 1, "host mouse difficulty emits exactly one original pressed signal")
		else:
			yield(_key(KEY_ENTER), "completed")
	yield(_wait_scene("res://main.tscn"), "completed")
	if _done:
		return
	_stage("real_battle_started")
	_check(int(_api.call("get_context").get("battle_id", 0)) > 0, "mouse selections preserve normal Online prepare/ack/commit")
	if _phase == "full":
		yield(_run_ingame(), "completed")
	yield(_barrier("finished"), "completed")
	_finish()


func _selection_element(player_index: int, id_fragment: String):
	if current_scene == null or not current_scene.has_method("_get_inventories"):
		return null
	var inventories = current_scene.call("_get_inventories")
	if inventories.empty():
		return null
	for child in inventories[player_index % inventories.size()].get_children():
		if not (child is BaseButton) or not child.is_visible_in_tree():
			continue
		var item = child.get("item")
		if item != null and not bool(child.get("is_special")) and not bool(child.get("is_locked")) and (id_fragment == "" or id_fragment in str(item.get("my_id"))):
			return child
	return null


func _watch(button, key: String) -> void:
	if button != null:
		_press_counts[key] = 0
		button.connect("pressed", self, "_on_observed_press", [key])


func _watch_weapon_hover(element) -> void:
	element.connect("mouse_entered", self, "_on_weapon_native_mouse_entered", [element])
	var inventory = element.get_parent()
	for signal_data in inventory.get_signal_list():
		var name = str(signal_data["name"])
		if name in ["element_hovered", "element_focused"] and signal_data["args"].size() == 1:
			inventory.connect(name, self, "_on_weapon_hover_observed", [name])


func _on_weapon_native_mouse_entered(element) -> void:
	_record_selection_event("native_mouse_entered", element)


func _on_weapon_hover_observed(element, kind: String) -> void:
	_record_selection_event(kind, element)


func _record_selection_event(kind: String, element) -> void:
	var focus_signal = get_root().get_node("FocusEmulatorSignal")
	if not _result.has("selection_events"):
		_result["selection_events"] = []
	_result["selection_events"].append({"kind": kind, "elapsed_msec": OS.get_ticks_msec() - _started, "element": str(element), "fs_control": str(focus_signal.get("_control")), "fs_player": int(focus_signal.get("_player_index")), "selected": current_scene.get("_has_player_selected").duplicate(), "weapons": str(current_scene.get("_player_weapons"))})


func _on_observed_press(key: String) -> void:
	_press_counts[key] = int(_press_counts.get(key, 0)) + 1
	if key == "weapon":
		_record_selection_event("pressed", get_root().get_node("FocusEmulatorSignal").get("_control"))


func _click(control, label: String, mouse_button: int = BUTTON_LEFT, hold_seconds: float = 0.0, local_point: Vector2 = Vector2(-1, -1)):
	yield(self, "idle_frame")
	if control == null or not is_instance_valid(control):
		_check(false, label + " click target exists")
		return
	var position = _input_position(control, local_point)
	_result["clicks"].append({"label": label, "path": str(control.get_path()), "position": [position.x, position.y], "button": mouse_button})
	var motion = InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	motion.control = Input.is_key_pressed(KEY_CONTROL)
	Input.parse_input_event(motion)
	yield(self, "idle_frame")
	if control is PopupMenu:
		if not _result.has("popup_observations"):
			_result["popup_observations"] = []
		_result["popup_observations"].append({"label": label, "current_index": control.get_current_index(), "mouse_filter": control.mouse_filter, "size": str(control.rect_size), "position": str(control.rect_global_position), "pointer": str(control.get_local_mouse_position())})
	var down = InputEventMouseButton.new()
	down.button_index = mouse_button
	down.position = position
	down.global_position = position
	down.pressed = true
	down.control = Input.is_key_pressed(KEY_CONTROL)
	Input.parse_input_event(down)
	yield(self, "idle_frame")
	if hold_seconds > 0.0:
		yield(create_timer(hold_seconds), "timeout")
	var up = InputEventMouseButton.new()
	up.button_index = mouse_button
	up.position = position
	up.global_position = position
	up.pressed = false
	up.control = Input.is_key_pressed(KEY_CONTROL)
	Input.parse_input_event(up)
	yield(create_timer(0.2), "timeout")


func _key(scancode: int):
	yield(self, "idle_frame")
	var event = InputEventKey.new()
	event.scancode = scancode
	event.pressed = true
	Input.parse_input_event(event)
	yield(self, "idle_frame")
	event = InputEventKey.new()
	event.scancode = scancode
	event.pressed = false
	Input.parse_input_event(event)
	yield(create_timer(0.2), "timeout")


func _held_key(scancode: int, pressed: bool):
	yield(self, "idle_frame")
	var event = InputEventKey.new()
	event.scancode = scancode
	event.pressed = pressed
	Input.parse_input_event(event)
	yield(create_timer(0.2), "timeout")


func _wait_scene(path: String):
	yield(self, "idle_frame")
	var deadline = OS.get_ticks_msec() + 20000
	while not _done and (current_scene == null or current_scene.filename != path):
		if OS.get_ticks_msec() >= deadline:
			_check(false, "scene transition timed out waiting for " + path + "; current=" + (current_scene.filename if current_scene != null else "none"))
			_finish()
			return
		yield(create_timer(0.05), "timeout")


func _run_ingame():
	yield(self, "idle_frame")
	# Host-only test setup creates earned rewards/currency before the real timer
	# end. Original Main/Online end-wave, progression and shop callbacks run.
	if _role == "host":
		var ui_script = load("res://ui/menus/ingame/upgrades_ui.gd")
		for player in current_scene.get("_players"):
			player.get("current_stats")["health"] = 1000
			for weapon in player.get("current_weapons"):
				weapon.set_process(false)
		for index in range(_player_count):
			_run_data.call("add_gold", 1000, index)
			_run_data.get("players_data")[index].set("uses_ban", true)
			_run_data.get("players_data")[index].set("remaining_ban_token", 10)
			for _box in range(4):
				var consumable = ui_script.ConsumableToProcess.new()
				consumable.player_index = index
				consumable.consumable_data = load("res://items/consumables/item_box/item_box_data.tres").duplicate()
				current_scene.get("_consumables_to_process")[index].append(consumable)
			var upgrade = ui_script.UpgradeToProcess.new()
			upgrade.player_index = index
			upgrade.level = 2
			current_scene.get("_upgrades_to_process")[index].append(upgrade)
	yield(_barrier("rewards-set-up"), "completed")
	# Each peer opens ESC independently and clicks its real ResumeButton.
	# Sequential turns avoid simultaneous Online pause toggles in the harness.
	for index in range(_player_count):
		if index == _index:
			yield(_key(KEY_ESCAPE), "completed")
			yield(create_timer(0.3), "timeout")
			var pause = current_scene.get("_pause_menu")
			if _check(pause.visible and paused, "ESC opens actual pause menu for local player " + str(_index)):
				var resume = pause.get("_main_menu").get("_resume_button")
				_watch(resume, "battle-resume")
				yield(_click(resume, "battle-resume"), "completed")
				_check(not pause.visible and not paused, "mouse Resume closes actual pause menu")
				_check(int(_press_counts.get("battle-resume", 0)) == 1, "one Resume click emits one original signal")
			yield(create_timer(0.3), "timeout")
		yield(_barrier("pause-tested-" + str(index)), "completed")
	if _role == "host":
		current_scene.get("_wave_timer").start(1.0)
	while not _done and (current_scene == null or current_scene.get_node_or_null("UI/CoopUpgradesUI") == null or not current_scene.get_node("UI/CoopUpgradesUI").visible):
		yield(create_timer(0.1), "timeout")
	if _done:
		return
	_stage("real_rewards_loaded")
	yield(create_timer(0.6), "timeout")
	yield(_screenshot("rewards"), "completed")
	var ui = current_scene.get("_coop_upgrades_ui")
	var quick_chat = _online.get_node("BrotatoOnlineQuickChatWheel")
	var chat_sequence = int(quick_chat.get("_local_seq"))
	yield(_held_key(KEY_CONTROL, true), "completed")
	yield(_click(ui, "native-quickchat-wheel", BUTTON_LEFT, 0.1), "completed")
	yield(_held_key(KEY_CONTROL, false), "completed")
	_check(not bool(quick_chat.get("_wheel_active")) and is_instance_valid(quick_chat.get("_overlay_root")) and quick_chat.get("_overlay_root").is_visible_in_tree(), "original quick-chat wheel closes while its native overlay root persists")
	_check(int(quick_chat.get("_local_seq")) == chat_sequence, "center wheel release sends no chat message")
	var container = ui.call("_get_player_container", _index)
	var remote = (_index + 1) % _player_count
	var remote_container = ui.call("_get_player_container", remote)
	_watch(remote_container.get("_take_button"), "remote-crate")
	yield(_click(remote_container.get("_take_button"), "remote-crate"), "completed")
	_check(int(_press_counts.get("remote-crate", 0)) == 0, "cannot take a remote player's loot box")
	yield(_barrier("remote-crate-tested"), "completed")
	var items_before = int(_host_player()["item_count"])
	var take = container.get("_take_button")
	_watch(take, "crate-take")
	yield(_click(take, "crate-take"), "completed")
	yield(create_timer(0.5), "timeout")
	_check(int(_press_counts.get("crate-take", 0)) == 1, "one loot Take click emits one original signal")
	yield(_barrier("crate-take-tested"), "completed")
	_check(int(_host_player()["item_count"]) == items_before + 1, "loot Take adds exactly one item to authoritative local slot")
	var discard = container.get("_discard_button")
	var item = container.get("_item_data")
	var recycle_value = get_root().get_node("ItemService").call("get_recycling_value", int(_run_data.get("current_wave")), int(item.get("value")), _index, _has_property(item, "weapon_id"))
	var gold_before = int(_host_player()["gold"])
	items_before = int(_host_player()["item_count"])
	_watch(discard, "crate-recycle")
	yield(_click(discard, "crate-recycle"), "completed")
	yield(create_timer(0.5), "timeout")
	_check(int(_press_counts.get("crate-recycle", 0)) == 1, "one loot Recycle click emits one original signal")
	yield(_barrier("crate-recycle-tested"), "completed")
	_check(int(_host_player()["gold"]) == gold_before + int(recycle_value), "loot Recycle credits authoritative value once")
	_check(int(_host_player()["item_count"]) == items_before, "recycled box adds no authoritative inventory item")
	var ban = container.get("_ban_button")
	var reward_emulator = null
	for emulator in get_nodes_in_group("coopfix_mouse_emulators"):
		if int(emulator.get("player_index")) == _index and emulator.call("_find_control_base_data", ban) != null:
			reward_emulator = emulator
			break
	item = container.get("_item_data")
	var banned_id = item.get("my_id_hash")
	var tokens_before = int(_host_player()["tokens"])
	_watch(ban, "crate-ban")
	if _check(ban.visible and not ban.disabled, "original loot Ban available in isolated unlocked ban mode"):
		yield(_click(ban, "crate-ban"), "completed")
		yield(create_timer(0.5), "timeout")
		_check(int(_press_counts.get("crate-ban", 0)) == 1, "one loot Ban click emits one original signal")
	yield(_barrier("crate-ban-tested"), "completed")
	_check(int(_host_player()["tokens"]) == tokens_before - 1, "loot Ban consumes exactly one authoritative local token")
	_check(banned_id in _host_player()["banned_ids"], "loot Ban records the authoritative actual item id")
	# Default game settings require a held ban. Short mouse press must cancel;
	# keeping the actual button down must complete one original ban operation.
	get_root().get_node("ProgressData").get("settings")["holding_button"] = true
	item = container.get("_item_data")
	banned_id = item.get("my_id_hash")
	tokens_before = int(_host_player()["tokens"])
	var choosing_before = ui.get("_showing_option")[_index]
	yield(_click(ban, "crate-ban-short"), "completed")
	_check(ban.is_connected("button_up", container, "_on_BanButton_button_up"), "loot Ban retains original mouse release cancellation handler")
	_check(not bool(container.get("is_pressing_b")), "short mouse Ban release cancels original local hold coroutine")
	yield(create_timer(1.2), "timeout")
	yield(_barrier("crate-short-ban-tested"), "completed")
	_check(int(_host_player()["tokens"]) == tokens_before and ui.get("_showing_option")[_index] == choosing_before, "held loot Ban short click cancels without spending an authoritative token")
	# Finish Host's local rewards first while clients still show a real box.
	# This reproduces a finished local FE waiting beside visible remote buttons,
	# where native mouse fall-through would otherwise bypass player ownership.
	for turn in range(2):
		var active = (_role == "host") == (turn == 0)
		var effects_before = _host_player()["effects_hash"]
		if active:
			yield(_click(ban, "crate-ban-hold", BUTTON_LEFT, 1.2), "completed")
			yield(create_timer(1.0), "timeout")
			get_root().get_node("ProgressData").get("settings")["holding_button"] = false
		yield(_barrier("crate-held-ban-tested-" + str(turn)), "completed")
		if active:
			_check(int(_host_player()["tokens"]) == tokens_before - 1, "held loot Ban spends exactly one authoritative token after a long mouse press")
			_check(banned_id in _host_player()["banned_ids"], "held loot Ban records the authoritative actual item id")
			var upgrade_ui = container.call("_get_upgrade_uis")[0]
			var upgrade_button = upgrade_ui.get("button")
			_watch(upgrade_button, "upgrade")
			yield(_click(upgrade_button, "upgrade"), "completed")
			yield(create_timer(0.5), "timeout")
			_check(int(_press_counts.get("upgrade", 0)) == 1, "one upgrade choice emits one original signal")
		yield(_barrier("upgrade-tested-" + str(turn)), "completed")
		if active:
			_check(_host_player()["effects_hash"] != effects_before, "upgrade choice applies original authoritative player stat effects")
		if turn == 0:
			if _role == "host":
				_check(reward_emulator != null and int(reward_emulator.get("player_index")) == -1, "original local reward FE finishes while a remote box remains visible")
				var remote_take = remote_container.get("_take_button")
				var remote_discard = remote_container.get("_discard_button")
				_watch(remote_take, "finished-local-remote-take")
				_watch(remote_discard, "finished-local-remote-recycle")
				_check(remote_take.is_visible_in_tree() and remote_discard.is_visible_in_tree(), "remote reward controls remain visible after local finish")
				yield(_click(remote_take, "finished-local-remote-take"), "completed")
				yield(_click(remote_discard, "finished-local-remote-recycle"), "completed")
				_check(int(_press_counts.get("finished-local-remote-take", 0)) == 0 and int(_press_counts.get("finished-local-remote-recycle", 0)) == 0, "finished local rewards cannot mouse-activate still-visible remote Take or Recycle")
			var remote_before = _host_player(remote).duplicate(true)
			yield(_barrier("finished-local-remote-blocked"), "completed")
			_check(JSON.print(_host_player(remote)) == JSON.print(remote_before), "blocked mouse input after local finish preserves authoritative remote reward state")
	yield(_wait_scene(str(_run_data.call("get_shop_scene_path"))), "completed")
	if _done:
		return
	_stage("real_shop_loaded")
	yield(create_timer(1.0), "timeout")
	yield(_barrier("shop-loaded"), "completed")
	yield(_screenshot("shop"), "completed")
	yield(_run_shop(), "completed")


func _run_shop():
	yield(self, "idle_frame")
	var container = current_scene.call("_get_coop_player_container", _index)
	var remote = (_index + 1) % _player_count
	var remote_container = current_scene.call("_get_coop_player_container", remote)
	var remote_buy = remote_container.get("shop_items_container").get("_shop_items")[0].get("_button")
	var remote_gold = int(_host_player(remote)["gold"])
	_watch(remote_buy, "remote-buy")
	yield(_click(remote_buy, "remote-buy"), "completed")
	_check(int(_press_counts.get("remote-buy", 0)) == 0, "mouse cannot purchase from remote shop")
	yield(_barrier("remote-shop-tested"), "completed")
	_check(int(_host_player(remote)["gold"]) == remote_gold, "remote shop click preserves authoritative remote money")
	var slot = container.get("shop_items_container").get("_shop_items")[0]
	var buy = slot.get("_button")
	var popup = container.get("item_popup")
	# Hover is an input operation too: it must display original item details.
	yield(_motion(buy), "completed")
	_check(popup.visible and popup.get("_item_data") != null, "mouse shop hover displays original item detail popup")
	var lock = slot.get("_lock_button")
	_watch(lock, "shop-lock")
	if _check(lock.visible and lock.is_visible_in_tree(), "original local Lock button is visible"):
		yield(_click(lock, "shop-lock"), "completed")
		yield(create_timer(0.5), "timeout")
		_check(bool(slot.get("locked")), "mouse Lock toggles original shop item's lock state")
		_check(int(_press_counts.get("shop-lock", 0)) == 1, "one Lock click emits one original pressed signal")
	yield(_barrier("shop-lock-tested"), "completed")
	_check(int(_host_player()["locked_count"]) == 1, "one locked item is stored in original authoritative local RunData")
	if lock.visible and lock.is_visible_in_tree():
		# Unlock restores conditions before buying the same slot.
		yield(_click(lock, "shop-unlock"), "completed")
		yield(create_timer(0.5), "timeout")
		_check(not bool(slot.get("locked")), "second mouse click unlocks the same shop item")
	yield(_barrier("shop-unlock-tested"), "completed")
	var gold_before = int(_host_player()["gold"])
	var price = int(slot.get("value"))
	var gear_before = int(_host_player()["item_count"]) + int(_host_player()["weapon_count"])
	_watch(buy, "shop-buy")
	yield(_click(buy, "shop-buy"), "completed")
	yield(create_timer(0.5), "timeout")
	_check(int(_press_counts.get("shop-buy", 0)) == 1, "one Buy click emits one original pressed signal")
	_check(not bool(slot.get("active")), "original purchased shop slot deactivates")
	yield(_barrier("buy-tested"), "completed")
	_check(int(_host_player()["gold"]) == gold_before - price, "mouse purchase charges original authoritative price once")
	_check(int(_host_player()["item_count"]) + int(_host_player()["weapon_count"]) == gear_before + 1, "mouse purchase adds exactly one original authoritative inventory element")
	var reroll = container.get("reroll_button")
	var rerolls_before = int(current_scene.get("_reroll_count")[_index])
	gold_before = int(_host_player()["gold"])
	price = int(current_scene.get("_reroll_price")[_index])
	_watch(reroll, "shop-reroll")
	yield(_click(reroll, "shop-reroll"), "completed")
	yield(create_timer(0.5), "timeout")
	_check(int(_press_counts.get("shop-reroll", 0)) == 1, "one Refresh click emits one original signal")
	_check(int(current_scene.get("_reroll_count")[_index]) == rerolls_before + 1, "mouse Refresh advances original reroll count once")
	yield(_barrier("reroll-tested"), "completed")
	_check(int(_host_player()["gold"]) == gold_before - price, "mouse Refresh charges original authoritative reroll price once")
	var ban_slot = null
	var shop_banned_id = null
	var shop_tokens_before = 0
	for candidate in container.get("shop_items_container").get("_shop_items"):
		if candidate.get("active") and not _has_property(candidate.get("item_data"), "weapon_id"):
			ban_slot = candidate
			break
	if _check(ban_slot != null, "actual shop offers an item eligible for Ban"):
		var shop_ban = ban_slot.get("_ban_button")
		shop_banned_id = ban_slot.get("item_data").get("my_id_hash")
		shop_tokens_before = int(_host_player()["tokens"])
		get_root().get_node("ProgressData").get("settings")["holding_button"] = true
		yield(_click(shop_ban, "shop-ban-short"), "completed")
		yield(_barrier("shop-short-ban-tested"), "completed")
		_check(int(_host_player()["tokens"]) == shop_tokens_before, "held shop Ban short click spends no authoritative token")
		yield(_click(shop_ban, "shop-ban-hold", BUTTON_LEFT, 1.2), "completed")
		yield(create_timer(1.0), "timeout")
		get_root().get_node("ProgressData").get("settings")["holding_button"] = false
	yield(_barrier("shop-ban-tested"), "completed")
	if ban_slot != null:
		_check(int(_host_player()["tokens"]) == shop_tokens_before - 1, "held shop Ban spends exactly one authoritative token")
		_check(shop_banned_id in _host_player()["banned_ids"], "held shop Ban records the authoritative actual item")
	var gear = container.get("player_gear_container")
	var inventory_element = gear.get("weapons_container").call("get_element", 0)
	_watch(inventory_element, "inventory")
	yield(_click(inventory_element, "inventory"), "completed")
	_check(popup.visible and bool(popup.get("_focused")), "mouse weapon inventory opens focused original details")
	yield(_screenshot("inventory-popup"), "completed")
	var cancel = popup.get("_cancel_button")
	_watch(cancel, "popup-cancel")
	yield(_click(cancel, "popup-cancel"), "completed")
	_check(not bool(popup.get("_focused")), "mouse Cancel exits focused item popup")
	_check(int(_press_counts.get("popup-cancel", 0)) == 1, "one details Cancel click emits one original signal")
	# Reopen and recycle an actual backpack weapon through the real popup.
	inventory_element = gear.get("weapons_container").call("get_element", 0)
	yield(_click(inventory_element, "inventory-reopen"), "completed")
	var recycle = popup.get("_discard_button")
	var weapons_before = int(_host_player()["weapon_count"])
	_watch(recycle, "inventory-recycle")
	yield(_click(recycle, "inventory-recycle"), "completed")
	yield(create_timer(0.5), "timeout")
	_check(int(_press_counts.get("inventory-recycle", 0)) == 1, "one backpack Recycle click emits one original signal")
	yield(_barrier("inventory-tested"), "completed")
	_check(int(_host_player()["weapon_count"]) == weapons_before - 1, "mouse backpack Recycle removes exactly one authoritative local weapon")
	# Pause-layer regression: the same visible shop button's coordinates must
	# never buy through the full-screen pause panel.
	if _role == "host":
		yield(_key(KEY_ESCAPE), "completed")
		yield(create_timer(0.3), "timeout")
		var pause = current_scene.get("_pause_menu")
		yield(_screenshot("shop-pause"), "completed")
		var masked_slot = container.get("shop_items_container").get("_shop_items")[0]
		gold_before = int(_run_data.call("get_player_gold", _index))
		_watch(masked_slot.get("_button"), "masked-shop-buy")
		yield(_click(masked_slot.get("_button"), "masked-shop-buy"), "completed")
		_check(int(_press_counts.get("masked-shop-buy", 0)) == 0 and int(_run_data.call("get_player_gold", _index)) == gold_before, "pause overlay blocks mouse purchase through its background")
		var options = pause.get("_main_menu").get_node("%OptionsButton")
		_watch(options, "pause-options")
		yield(_click(options, "pause-options"), "completed")
		_check(not pause.get("_main_menu").visible, "mouse Options navigates actual pause submenu")
		var gameplay_tab = pause.find_node("Gameplay_but", true, false)
		yield(_click(gameplay_tab, "pause-gameplay-tab"), "completed")
		var projectile_option = pause.find_node("ScoreStoringButton", true, false)
		if _check(projectile_option is OptionButton and projectile_option.is_visible_in_tree(), "actual pause gameplay OptionButton is visible"):
			yield(_scroll_to_control(projectile_option), "completed")
			var selected_before = projectile_option.selected
			var selected_next = (selected_before + 1) % projectile_option.get_item_count()
			yield(_motion(projectile_option), "completed")
			yield(_select_option_with_keyboard_open(projectile_option, selected_next, "pause-option-keyboard-mouse"), "completed")
			_check(projectile_option.selected == selected_next, "mouse selects original pause OptionButton after keyboard opens its native popup")
			yield(_select_option_with_keyboard_open(projectile_option, selected_before, "pause-option-restore", true), "completed")
			_check(projectile_option.selected == selected_before, "native pause OptionButton restores isolated original setting")
			yield(_screenshot("pause-options"), "completed")
		yield(_key(KEY_ESCAPE), "completed")
		var resume = pause.get("_main_menu").get("_resume_button")
		# Tab uses Online's original persistent native overlay. Observe its GUI
		# input at a safe background point; never activate Steam profiles/block
		# buttons or send any message to a real player.
		var player_list = _online.get_node("BrotatoOnlinePlayerListOverlay")
		yield(_held_key(KEY_TAB, true), "completed")
		var overlay = player_list.get("_overlay_root")
		_check(bool(player_list.get("_overlay_open")) and overlay.is_visible_in_tree() and pause.visible, "Tab opens original Online player list over ESC pause")
		overlay.connect("gui_input", self, "_on_overlay_gui_input")
		_overlay_mouse_downs = 0
		yield(_click(overlay, "player-list-native-background", BUTTON_LEFT, 0.0, Vector2(12, 12)), "completed")
		_check(_overlay_mouse_downs == 1, "Online player list retains exactly one native mouse GUI press while paused")
		_watch(resume, "player-list-masked-resume")
		yield(_click(resume, "player-list-masked-resume"), "completed")
		_check(int(_press_counts.get("player-list-masked-resume", 0)) == 0 and pause.visible and paused, "Online player list masks the underlying Pause Resume button")
		yield(_screenshot("online-player-list-pause"), "completed")
		yield(_held_key(KEY_TAB, false), "completed")
		_check(not bool(player_list.get("_overlay_open")) and pause.visible and paused, "releasing Tab restores original paused menu")
		yield(_click(resume, "shop-resume"), "completed")
		_check(not paused and not pause.visible, "mouse Resume restores original shop")
	yield(_barrier("shop-pause-tested"), "completed")
	# Ready must remain committed during mouse motion, then all players ready
	# through the original Online callbacks to reach the real next wave.
	var go = container.get("go_button")
	for index in range(_player_count):
		if index == _index:
			_watch(go, "shop-ready")
			yield(_click(go, "shop-ready"), "completed")
			yield(create_timer(0.5), "timeout")
			if current_scene != null and current_scene.has_method("_get_coop_player_container"):
				_check(bool(current_scene.get("_player_pressed_go_button")[_index]), "mouse Ready commits original local ready state")
				yield(_motion(container.get("shop_items_container").get("_shop_items")[0].get("_button")), "completed")
				_check(bool(current_scene.get("_player_pressed_go_button")[_index]), "mouse movement preserves Ready without another click")
			_check(int(_press_counts.get("shop-ready", 0)) == 1, "one Ready click emits one original signal")
		yield(_barrier("ready-tested-" + str(index)), "completed")
	yield(_wait_scene("res://main.tscn"), "completed")
	if not _done:
		_check(int(_run_data.get("current_wave")) == 2, "original Online Ready starts synchronized wave two")
		_stage("real_next_wave_started")


func _motion(control):
	yield(self, "idle_frame")
	var position = _input_position(control)
	var motion = InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	Input.parse_input_event(motion)
	yield(create_timer(0.2), "timeout")


func _select_option_with_keyboard_open(option: OptionButton, selected: int, label: String, mouse_open: bool = false):
	if mouse_open:
		yield(_click(option, label + "-open"), "completed")
	else:
		# InputService normalizes keyboard/controller accept into ui_accept_DEVICE.
		# Inject that input through SceneTree, without invoking the FE or menu.
		var device = -1
		for emulator in get_nodes_in_group("coopfix_mouse_emulators"):
			if emulator.is_processing_input() and _api.call("owns_player", int(emulator.get("player_index"))) and emulator.call("_find_control_base_data", option) != null:
				device = int(emulator.get("_device"))
				break
		_check(device >= 0, label + " owned original UI input device")
		var accept = InputEventAction.new()
		accept.action = "ui_accept_%s" % device
		accept.pressed = true
		Input.parse_input_event(accept)
		yield(self, "idle_frame")
		accept = InputEventAction.new()
		accept.action = "ui_accept_%s" % device
		accept.pressed = false
		Input.parse_input_event(accept)
		yield(create_timer(0.2), "timeout")
	var popup = option.get_popup()
	if _check(popup.is_visible_in_tree() and get_root().get_modal_stack_top() == popup, label + " original UI input opens native PopupMenu"):
		yield(_screenshot(label + "-open"), "completed")
		var point = Vector2(popup.rect_size.x * 0.5, popup.rect_size.y * (float(selected) + 0.5) / float(option.get_item_count()))
		yield(_click(popup, label, BUTTON_LEFT, 0.0, point), "completed")
		_check(not popup.is_visible_in_tree(), label + " mouse closes native PopupMenu through original selection")


func _scroll_to_control(control: Control):
	yield(self, "idle_frame")
	var scroll = control.get_parent()
	while scroll != null and not scroll is ScrollContainer:
		scroll = scroll.get_parent()
	if scroll == null:
		return
	for attempt in range(20):
		var center = control.get_global_transform_with_canvas().xform(control.rect_size * 0.5)
		var local = scroll.get_global_transform_with_canvas().affine_inverse().xform(center)
		if Rect2(Vector2.ZERO, scroll.rect_size).has_point(local):
			_check(true, "native mouse wheel brings actual option inside scroll clipping")
			return
		var direction = BUTTON_WHEEL_UP if local.y < 0 else BUTTON_WHEEL_DOWN
		yield(_click(scroll, "pause-options-scroll-" + str(attempt), direction), "completed")
	_check(false, "native mouse wheel reaches actual option inside scroll clipping")


func _input_position(control, local_point: Vector2 = Vector2(-1, -1)) -> Vector2:
	# Godot transforms physical input into its logical stretch viewport. Project
	# a Control's center back into the physical input coordinates first.
	var center = control.get_global_transform_with_canvas().xform(control.rect_size * 0.5 if local_point.x < 0 else local_point)
	return control.get_viewport().get_final_transform().xform(center)


func _on_overlay_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		_overlay_mouse_downs += 1


func _has_property(object, property: String) -> bool:
	for entry in object.get_property_list():
		if str(entry["name"]) == property:
			return true
	return false


func _screenshot(label: String):
	yield(VisualServer, "frame_post_draw")
	var screenshot = get_root().get_texture().get_data()
	screenshot.flip_y()
	var path = _output.get_basename() + "-" + label + ".png"
	_check(screenshot.save_png(path) == OK, label + " actual engine screenshot saved")
	if not _result.has("screenshots"):
		_result["screenshots"] = []
	_result["screenshots"].append(path)


func _finish() -> void:
	if _done:
		return
	_done = true
	if current_scene != null and current_scene.filename == "res://ui/menus/run/weapon_selection.tscn":
		_result["selection_state_at_finish"] = _online.get_node("BrotatoOnlineMenuSyncManager").call("build_selection_state")
		var router = get_root().get_node_or_null(PATCH_PATH + "/MouseRouter")
		_result["native_overlay_at_finish"] = router.call("_native_overlay_active") if router != null else false
	_result["elapsed_msec"] = OS.get_ticks_msec() - _started
	_result["press_counts"] = _press_counts
	_result["passed"] = _result["failures"].empty()
	if _output.is_abs_path():
		var file = File.new()
		if file.open(_output, File.WRITE) == OK:
			file.store_string(JSON.print(_result, "\t"))
			file.close()
	print("MOUSE_UI_TEST_RESULT=", JSON.print(_result))
	if _role == "host":
		yield(create_timer(0.5), "timeout")
	quit(0 if bool(_result["passed"]) else 1)
