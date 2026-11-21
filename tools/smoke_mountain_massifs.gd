extends SceneTree
## Проверка GPU: исходный/адаптированный контур, шов цилиндра и частичный туман.
const Models := preload("res://view/map/landscape_models.gd")
var _view: MapView
var _camera: Camera3D
var _game: Game
var _stage: Node3D
var _case := 0
var _phase := 0
var _frames := 0
var _full_pixels := 0
var _partial_tile := -1
var _failures: PackedStringArray = []

func _initialize() -> void:
	root.size = Vector2i(1000, 800)
	call_deferred("_setup")

func _setup() -> void:
	_stage = Node3D.new()
	root.add_child(_stage)
	_game = TestCase.blank_game(18, 14)
	var grid := _game.state.map.grid
	var anchor := grid.index_of(0 if _case == 1 else 7, 6)
	var cfg: Dictionary = Models.config()["mountain_massif"]
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(str(cfg["manifest"])))
	var footprint: Array = manifest["footprint_axial"]
	if _case == 2:
		footprint = [[0, 0], [1, 0], [0, 1]]
	for cell in footprint:
		var tile := grid.index_of_axial(grid.axial_of(anchor) + Vector2i(int(cell[0]), int(cell[1])))
		_game.state.map.relief[tile] = GameMap.RELIEF_MOUNTAIN
	_partial_tile = anchor
	_view = MapView.new()
	_view.build(_game)
	_stage.add_child(_view)
	for layer in _view._layers:
		for copy in 3:
			_view._layers[layer][copy].visible = layer == "mountain_massifs"
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("151c25")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.5
	_stage.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -35, 0)
	light.light_energy = 0.6
	_stage.add_child(light)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 8
	_stage.add_child(_camera)
	var center := grid.world_position(anchor)
	var target := Vector3(center.x + .7, 0, center.y)
	_camera.position = target + Vector3.UP * 15
	_camera.look_at(target, Vector3.FORWARD)
	_camera.current = true
	_view.set_reveal_all(true)
	_phase = 0
	_frames = 0

func _process(_delta: float) -> bool:
	if _view == null:
		return false
	_frames += 1
	if _frames < 10:
		return false
	_frames = 0
	var image := root.get_texture().get_image()
	var background := image.get_pixel(0, 0)
	var colored := 0
	var wrong := 0
	var grid := _game.state.map.grid
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var color := image.get_pixel(x, y)
			if absf(color.r - background.r) + absf(color.g - background.g) + absf(color.b - background.b) < .04:
				continue
			colored += 1
			var point := _camera.project_ray_origin(Vector2(x + .5, y + .5))
			var tile := grid.index_at_world(point.x, point.z)
			if tile < 0:
				wrong += 1
				continue
			var local := Vector2(point.x, point.z) - grid.world_position(tile)
			local.x -= round(local.x / grid.world_width()) * grid.world_width()
			var distance := 1.0
			for direction in HexGrid.DIR_COUNT:
				var angle := -direction * PI / 3.0
				distance = minf(distance, HexGrid.SQRT3 * .5 - local.dot(Vector2(cos(angle), sin(angle))))
			if distance < .06:
				continue # MSAA на самой границе может смешивать соседние пиксели.
			if not _game.state.map.is_mountain(tile) or (_phase == 1 and tile != _partial_tile):
				wrong += 1
	var label := "case=%d phase=%d" % [_case, _phase]
	if wrong > 0:
		_failures.append(label + ": изображение выходит за разрешённые клетки (%d пикселей)" % wrong)
	if _phase == 0:
		_full_pixels = colored
		if colored < 100:
			_failures.append(label + ": гора не отрисована")
		var custom: Color = _view._layers["mountain_massifs"][1].multimesh.get_instance_custom_data(0)
		if absf(custom.r - 1) > .001:
			_failures.append(label + ": потерян идентификатор MultiMesh")
		_view.set_reveal_all(false)
		_game.state.players[0].revealed[_partial_tile] = 1
		_view.refresh_fog(_game.state.players[0])
	elif _phase == 1:
		if colored < 10 or colored >= _full_pixels * .9:
			_failures.append(label + ": частичная разведка не разделяет массив по клеткам")
		_game.state.players[0].revealed.fill(0)
		_view.refresh_fog(_game.state.players[0])
	else:
		if colored != 0:
			_failures.append(label + ": неразведанные горы видны (%d пикселей)" % colored)
	print("GPU %s: окрашенных пикселей %d, вне контура %d" % [label, colored, wrong])
	_phase += 1
	if _phase == 3:
		_case += 1
		if _case == 3:
			for message in _failures:
				push_error(message)
			print("Проверок GPU: 9, ошибок: ", _failures.size())
			quit(0 if _failures.is_empty() else 1)
		else:
			_view = null
			_stage.queue_free()
			call_deferred("_setup")
	return false
