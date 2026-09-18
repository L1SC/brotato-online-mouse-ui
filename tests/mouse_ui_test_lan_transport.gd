extends "res://mods-unpacked/six666-BrotatoOnline/scripts/lan_transport.gd"

# Keep the isolated tests away from a player's running game on port 27462.
func start_host(_port: int = 27462) -> int:
	return .start_host(29762)
