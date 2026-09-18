extends Node

const MOD_DIR = "CoopFix-OnlineMouseUI"


func _init() -> void:
	var mod_path = ModLoaderMod.get_unpacked_dir().plus_file(MOD_DIR)
	ModLoaderMod.install_script_extension(mod_path.plus_file("extensions/focus_emulator.gd"))
	ModLoaderMod.install_script_extension(mod_path.plus_file("extensions/inventory.gd"))
	ModLoaderMod.install_script_extension(mod_path.plus_file("extensions/weapon_selection.gd"))


func _ready() -> void:
	var path = ModLoaderMod.get_unpacked_dir().plus_file(MOD_DIR)
	var router = load(path.plus_file("mouse_router.gd")).new()
	router.name = "MouseRouter"
	add_child(router)
