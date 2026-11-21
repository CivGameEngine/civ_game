extends TestCase
const Massifs := preload("res://view/map/mountain_massifs.gd")
const Models := preload("res://view/map/landscape_models.gd")

func _footprint() -> Array:
	var cfg: Dictionary = Models.config()["mountain_massif"]
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(str(cfg["manifest"])))
	return manifest["footprint_axial"]

func _stamp(map: GameMap, anchor: int, steps: int) -> Array[int]:
	var tiles: Array[int] = []
	for cell in _footprint():
		var point := Vector2i(int(cell[0]), int(cell[1]))
		for step in steps:
			point = Vector2i(-point.y, point.x + point.y)
		var tile := map.grid.index_of_axial(map.grid.axial_of(anchor) + point)
		map.relief[tile] = GameMap.RELIEF_MOUNTAIN
		tiles.append(tile)
	return tiles

func test_nine_hex_massif_preserves_scale_rotation_and_horizontal_wrap() -> void:
	for steps in HexGrid.DIR_COUNT:
		var g := blank_game(18, 14)
		var map := g.state.map
		var tiles := _stamp(map, map.grid.index_of(0, 6), steps)
		var before := g.state.to_dict()
		var plan := Massifs.build(map, Models.config()["mountain_massif"], _footprint())
		check_eq(plan["groups"].size(), 1, "Девять клеток — один массив")
		var group: Dictionary = plan["groups"][0]
		check(group["native"], "Исходная модель не сжимается при совпадении контура")
		var transform: Transform3D = group["transform"]
		check_near(transform.basis.determinant(), 1.0)
		for cell in _footprint():
			var source := Vector3(HexGrid.SQRT3 * (float(cell[0]) + float(cell[1]) / 2), 0, 1.5 * float(cell[1]))
			var point := transform * source
			check(tiles.has(map.grid.index_at_world(point.x, point.z)), "Каждый гекс модели совпадает с горной клеткой")
		check_eq(g.state.to_dict(), before, "Планирование не меняет карту и ГПСЧ")

func test_irregular_groups_and_mask_keep_nonmountains_empty() -> void:
	var g := blank_game(16, 10)
	var map := g.state.map
	var tiles: Array[int] = [map.grid.index_of(0, 4), map.grid.index_of(15, 4), map.grid.index_of(0, 5), map.grid.index_of(8, 6)]
	for tile in tiles:
		map.relief[tile] = GameMap.RELIEF_MOUNTAIN
	var plan := Massifs.build(map, Models.config()["mountain_massif"], _footprint())
	check_eq(plan["groups"].size(), 2, "Соседи на шве карты принадлежат одной группе")
	var labels: PackedInt32Array = plan["labels"]
	check_eq(labels[tiles[0]], labels[tiles[1]])
	for tile in map.size():
		var color: Color = plan["image"].get_pixel(map.grid.col_of(tile), map.grid.row_of(tile))
		var id := roundi(color.r * 255) + 256 * roundi(color.g * 255)
		check_eq(id != 0, tiles.has(tile), "Модель ограничена горными клетками")
		if id == 0:
			continue
		var edges := roundi(color.b * 255)
		for direction in HexGrid.DIR_COUNT:
			var neighbor := map.grid.neighbor(tile, direction)
			var outside := neighbor < 0 or labels[neighbor] != id
			check_eq((edges & (1 << direction)) != 0, outside, "Внутренние рёбра не разрывают массив")
	for group in plan["groups"]:
		check(not group["native"], "Произвольный контур адаптируется")
		var transform: Transform3D = group["transform"]
		check(transform.is_finite() and transform.basis.determinant() > 0, "Нет зеркального или вырожденного масштаба")

func test_map_replaces_old_peaks_preserves_pbr_and_rebuilds_after_changes() -> void:
	var g := blank_game(18, 14)
	_stamp(g.state.map, g.state.map.grid.index_of(5, 6), 1)
	var before := g.state.to_dict()
	var view := MapView.new()
	view.build(g)
	check_eq(g.state.to_dict(), before)
	var mm: MultiMesh = view._layers["mountain_massifs"][1].multimesh
	check_eq(mm.instance_count, 1, "Один экземпляр на девять клеток")
	check_eq(mm.mesh.get_meta("source_asset"), Models.config()["mountain_massif"]["asset"])
	check(mm.use_custom_data, "Включены данные групп для шейдера")
	for key in view._layers:
		check(not str(key).begins_with("landscape_mountain"), "Старые модели больше не размещаются")
	var material := mm.mesh.surface_get_material(0) as ShaderMaterial
	check(material.get_shader_parameter("has_texture"), "Атлас цвета подключён")
	check(material.get_shader_parameter("has_normal"), "Нормали подключены")
	check(material.get_shader_parameter("has_roughness"), "Шероховатость подключена")
	check_eq(material.get_shader_parameter("fog_tex"), view.fog_texture)
	view.refresh_geometry({"terrain": true})
	check_eq(view._layers["mountain_massifs"][1].multimesh, mm, "Вырубка лесов не пересобирает неизменные горы")
	view.set_reveal_all(true)
	check_eq(material.get_shader_parameter("reveal_all"), true)
	g.state.map.relief.fill(GameMap.RELIEF_FLAT)
	view.refresh_geometry({"terrain": true})
	check_eq(view._layers["mountain_massifs"][1].multimesh.instance_count, 0, "Удалённый рельеф не оставляет старых массивов")
	view.free()

func test_large_ranges_use_complete_models_and_bounded_connected_remainders() -> void:
	var g := blank_game(24, 16)
	var map := g.state.map
	for row in range(5, 10):
		for col in range(5, 12):
			map.relief[map.grid.index_of(col, row)] = GameMap.RELIEF_MOUNTAIN
	var plan := Massifs.build(map, Models.config()["mountain_massif"], _footprint())
	var covered := {}
	var native_count := 0
	for group in plan["groups"]:
		if group["native"]:
			native_count += 1
		check(group["tiles"].size() <= int(Models.config()["mountain_massif"]["max_tiles"]), "Нет чрезмерно растянутых групп")
		var visited := {group["tiles"][0]: true}
		var queue: Array = [group["tiles"][0]]
		var cursor := 0
		while cursor < queue.size():
			for neighbor in map.grid.neighbors(int(queue[cursor])):
				if group["tiles"].has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
			cursor += 1
		check_eq(visited.size(), group["tiles"].size(), "Один массив занимает связную группу")
		for tile in group["tiles"]:
			check(not covered.has(tile), "Массивы не перекрываются")
			covered[tile] = true
	check(native_count > 0, "Целые модели размещаются и внутри длинной цепи")
	check_eq(covered.size(), 35, "Все горные клетки получили новую модель")

func test_new_maps_generate_whole_massifs_with_unchanged_saved_geography() -> void:
	var data := GameData.get_default()
	check_eq(data.setup["mountain_generation"]["footprint_axial"], _footprint(),
		"Контур генерации согласован с моделью")
	for map_type in data.setup["map_types"]:
		var g := Game.new_game(data, {"map_size": "DUEL", "map_type": str(map_type["id"]), "seed": 42, "humans": [0]})
		var map := g.state.map
		var before := g.state.to_dict()
		var plan := Massifs.build(map, Models.config()["mountain_massif"], _footprint())
		check(not plan["groups"].is_empty(), "Есть горные массивы")
		for group in plan["groups"]:
			check(group["native"], "Все новые горы используют исходную модель целиком")
			check_eq(group["tiles"].size(), 9)
		var covered := 0
		for group in plan["groups"]:
			covered += group["tiles"].size()
		check_eq(covered, map.relief.count(GameMap.RELIEF_MOUNTAIN))
		check_eq(g.state.to_dict(), before, "Показ карты не меняет географию сохранения")
		var restored := GameMap.from_dict(map.to_dict(), data)
		check_eq(restored.to_dict(), map.to_dict(), "Существующий формат сохраняет массивы без новых полей")
