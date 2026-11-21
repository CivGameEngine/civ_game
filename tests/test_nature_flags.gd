extends TestCase
const Flags := preload("res://view/map/nature_flags.gd")

func test_atlas_covers_every_resource_and_feature() -> void:
	var data := GameData.get_default()
	for id in data.resource_ids:
		check(Flags.index(id) >= 0, "Нужен флаг ресурса " + id)
	for id in data.features:
		check(Flags.index(id) >= 0, "Нужен флаг особенности " + id)
	check_eq(Flags.regions().size(), 60)
	for rect in Flags.regions():
		check(rect.x >= 0 and rect.y >= 0 and rect.x + rect.z <= 1.001 and rect.y + rect.w <= 1.001,
			"Область внутри атласа")

func test_flags_respect_exploration_technology_and_removed_feature() -> void:
	var g := blank_game(8, 6)
	g.state.map.feature[10] = "WOODS"
	g.state.map.resource[10] = "IRON"
	g.state.map.relief[12] = GameMap.RELIEF_MOUNTAIN
	for index in g.data.features.size():
		g.state.map.feature[20 + index] = str(g.data.features.keys()[index])
	var player := g.state.player(0)
	var view := MapView.new()
	view.build(g)
	view.refresh_resources(player)
	var layer: MultiMeshInstance3D = view._layers["nature_flags"][1]
	check_eq(layer.multimesh.instance_count, 0, "Неразведанный тайл скрыт")
	player.revealed[10] = 1
	view.refresh_resources(player)
	check_eq(layer.multimesh.instance_count, 0, "У леса нет флага, железо скрыто до технологии")
	player.known_techs["BRONZE_WORKING"] = true
	view.refresh_resources(player)
	check_eq(layer.multimesh.instance_count, 1, "Флаг есть только у ресурса")
	var trees_before := _forest_count(view)
	check(trees_before >= 1, "Лесные тайлы используют модели Blender")
	g.state.map.feature[10] = ""
	view.refresh_geometry({"terrain": true})
	view.refresh_resources(player)
	check_eq(layer.multimesh.instance_count, 1, "Удаление особенности не убрало ресурсный флаг")
	check_eq(_forest_count(view), trees_before - 1, "Исчезла модель только вырубленного тайла")
	check(not view._layers.has("forest_sprites") and not view._layers.has("resources"), "Плоские деревья и старые маркеры отключены")
	check(view._layers.has("mountain_massifs"), "Горы используют новый массив Blender")
	check_eq(view._layers["mountain_massifs"][1].multimesh.instance_count, 1)
	view.free()

func _forest_count(view: MapView) -> int:
	var count := 0
	for key in view._layers:
		if str(key).begins_with("landscape_forest_") or str(key).begins_with("landscape_jungle_tile_"):
			count += view._layers[key][1].multimesh.instance_count
	return count

func test_biome_mesh_uses_each_atlas_region() -> void:
	var g := blank_game(8, 6)
	for index in MapStyle.BIOME_ORDER.size():
		g.state.map.terrain[index] = MapStyle.BIOME_ORDER[index]
		check_eq(MapStyle.biome_index(g.state.map, index), index)
	var mesh := TerrainMeshBuilder.build_terrain(g.state.map)
	var arrays := mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	for index in 8:
		check(uvs.has(Vector2(index, 0)), "Поверхность биома имеет свою область атласа")
	var water := TerrainMeshBuilder.build_water(g.state.map)
	var water_uvs: PackedVector2Array = water.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	for index in [5, 6, 7]:
		check(water_uvs.has(Vector2(index, 0)), "Вода имеет отдельную текстуру")
