extends SceneTree
## Снимок настоящей игровой сцены с фокусом на крупнейшей горной группе.
var _main: Node3D
var _frames := 0

func _initialize() -> void:
	_main = load("res://view/main.tscn").instantiate()
	_main.fixed_seed = 42
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main._set_reveal(true)
		var largest: Dictionary = {}
		var native_count := 0
		var best_score := -INF
		for group in _main.map_view._massif_plan["groups"]:
			if group["native"]:
				native_count += 1
			var score := float(group["tiles"].size())
			for tile in group["tiles"]:
				var terrain: String = _main.game.state.map.terrain[tile]
				score += 1.0 if terrain == "GRASS" else (0.5 if terrain == "PLAINS" else 0.0)
			if score > best_score:
				best_score = score
				largest = group
		var transform: Transform3D = largest["transform"]
		var center := transform * Vector3(-.1, 0, -.2)
		center.y = 0
		_main.camera_rig.focus(center)
		_main.camera_rig.distance = 18
		_main.camera_rig.target_distance = 18
		_main.camera_rig._update_camera()
		print("Горные клетки: %d, массивов: %d, целых моделей: %d, крупнейшая группа: %d" % [
			_main.game.state.map.relief.count(GameMap.RELIEF_MOUNTAIN),
			_main.map_view._massif_plan["groups"].size(), native_count, largest["tiles"].size()])
	if _frames >= 3:
		_main.set_process(false)
	if _frames == 30:
		var args := OS.get_cmdline_user_args()
		var destination := args[0] if not args.is_empty() else "res://docs/mountain-massifs-in-game.png"
		var error := root.get_texture().get_image().save_png(destination)
		print("Снимок карты: ", error_string(error))
		quit(0 if error == OK else 1)
	return false
