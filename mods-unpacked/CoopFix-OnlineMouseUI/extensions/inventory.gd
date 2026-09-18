extends "res://ui/menus/shop/inventory.gd"


func on_element_hovered(element: InventoryElement) -> void:
	if not _uses_online_mouse_router():
		.on_element_hovered(element)


func on_element_unhovered(element: InventoryElement) -> void:
	if not _uses_online_mouse_router():
		.on_element_unhovered(element)


func _uses_online_mouse_router() -> bool:
	# Online enables native inventory hover. The router already emits FE focus;
	# a second native hover can clear a weapon selection after its pressed signal.
	var router = get_node_or_null("/root/ModLoader/CoopFix-OnlineMouseUI/MouseRouter")
	return router != null and router.is_online()
