extends "res://ui/menus/run/weapon_selection.gd"


func _on_element_focused(element: InventoryElement, inventory_player_index: int, displayPanelData: bool = true) -> void:
	var router = get_node_or_null("/root/ModLoader/CoopFix-OnlineMouseUI/MouseRouter")
	var index = FocusEmulatorSignal.get_player_index(element)
	if router != null and router.is_online() and index >= 0 and index < _player_weapons.size():
		var selected = _player_weapons[index]
		# Online can apply delayed focus after confirming this same weapon.
		# Keep that confirmation; focusing a different weapon still cancels it.
		if _has_player_selected[index] and selected != null and element.item != null and selected.my_id_hash == element.item.my_id_hash:
			return
	._on_element_focused(element, inventory_player_index, displayPanelData)
