extends TestCase
const Models := preload("res://view/map/landscape_models.gd")

func test_map_uses_textured_models_with_fog_and_stable_placement() -> void:
	var g := blank_game(8, 6)
	g.state.map.feature[10] = "WOODS"
	g.state.map.feature[11] = "RAINFOREST"
	g.state.map.relief[12] = GameMap.RELIEF_MOUNTAIN
	g.state.map.relief[13] = GameMap.RELIEF_MOUNTAIN
	g.state.map.terrain[13] = "SNOW"
	var state_before := g.state.to_dict()
	var view := MapView.new()
	view.build(g)
	check_eq(g.state.to_dict(), state_before, "Отрисовка не меняет симуляцию")
	check(not view._layers.has("crowns") and not view._layers.has("trunks") \
		and not view._layers.has("mountains"), "Примитивы не подменяют новые модели")
	check(view._layers.has("mountain_massifs"), "Горы заменены общим текстурированным массивом")
	check(not view._layers.has("landscape_mountain_snow_a"), "Старые снежные горы отключены")
	var transforms := {}
	for key in view._layers:
		if not str(key).begins_with("landscape_"):
			continue
		var node: MultiMeshInstance3D = view._layers[key][1]
		check(node.material_override == null, "Материалы поверхности сохранены")
		check(node.multimesh.mesh.has_meta("source_asset"), "Используется импортированный меш")
		for surface in node.multimesh.mesh.get_surface_count():
			var material := node.multimesh.mesh.surface_get_material(surface) as ShaderMaterial
			check(material != null, "Материал поддерживает туман")
			check_eq(material.get_shader_parameter("fog_tex"), view.fog_texture)
		transforms[key] = node.multimesh.get_instance_transform(0)
	view.refresh_geometry({"terrain": true})
	for key in transforms:
		check_eq(view._layers[key][1].multimesh.get_instance_transform(0), transforms[key], "Модель не скачет после обновления")
	view.set_reveal_all(true)
	for mesh in view._landscape_meshes.values():
		for surface in mesh.get_surface_count():
			check_eq(mesh.surface_get_material(surface).get_shader_parameter("reveal_all"), true)
	view.free()
