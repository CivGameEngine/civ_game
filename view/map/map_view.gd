class_name MapView
extends Node3D
## Отрисовка карты: плоские тайлы, вода, реки, горные массивы, леса и туман войны.
## Карта зациклена: рисуется в трёх копиях (слева, по центру, справа), камера
## «перескакивает» через шов незаметно.

const TERRAIN_SHADER := preload("res://view/map/shaders/terrain.gdshader")
const FEATURE_SHADER := preload("res://view/map/shaders/feature.gdshader")
const OVERLAY_SHADER := preload("res://view/map/shaders/overlay.gdshader")
const NatureFlags := preload("res://view/map/nature_flags.gd")
const FLAG_SHADER := preload("res://view/map/shaders/nature_flag.gdshader")
const FLAG_SHEET := preload("res://art/map_flags/nature_flags.png")
const BIOME_ATLAS := preload("res://art/terrain/biomes/biome_atlas.png")
const LandscapeModels := preload("res://view/map/landscape_models.gd")
const LANDSCAPE_SHADER := preload("res://view/map/shaders/landscape_model.gdshader")
const MASSIF_SHADER := preload("res://view/map/shaders/mountain_massif.gdshader")
const MountainMassifs := preload("res://view/map/mountain_massifs.gd")

var game: Game
var world_width: float
var fog_image: Image
var fog_texture: ImageTexture
var reveal_all := false
## Игрок, глазами которого показана карта (для высот неразведанных клеток).
var viewer: Player = null

var _materials: Array[ShaderMaterial] = []
var _copies: Array[Node3D] = []
## Слои отрисовки: имя -> [узел в копии 0, 1, 2].
var _layers := {}
var _terrain_mat: ShaderMaterial
var _feature_mat: ShaderMaterial
var _flag_mat: ShaderMaterial
var _water_mat: ShaderMaterial
var _river_mat: ShaderMaterial
var _border_mat: ShaderMaterial
var _improvement_meshes := {}
var _landscape_meshes: Dictionary = {}
var _massif_mesh: ArrayMesh
var _massif_plan: Dictionary = {}
var _massif_relief := PackedByteArray()
var _massif_terrain := PackedStringArray()


func build(g: Game) -> void:
	game = g
	for c in get_children():
		c.queue_free()
	_copies.clear()
	_materials.clear()
	_layers.clear()
	_landscape_meshes.clear()
	_massif_mesh = null
	_massif_plan.clear()
	_massif_relief.clear()
	_massif_terrain.clear()
	var map := game.state.map
	world_width = map.grid.world_width(MapStyle.HEX_SIZE)
	fog_image = Image.create(map.width, map.height, false, Image.FORMAT_RGBA8)
	fog_image.fill(Color.BLACK)
	fog_texture = ImageTexture.create_from_image(fog_image)

	_terrain_mat = _make_material(TERRAIN_SHADER)
	_terrain_mat.set_shader_parameter("biome_atlas", BIOME_ATLAS)
	_feature_mat = _make_material(FEATURE_SHADER)
	_flag_mat = _make_material(FLAG_SHADER)
	_flag_mat.set_shader_parameter("flag_sheet", FLAG_SHEET)
	_flag_mat.set_shader_parameter("regions", NatureFlags.regions())
	_water_mat = _make_material(OVERLAY_SHADER)
	_water_mat.set_shader_parameter("biome_atlas", BIOME_ATLAS)
	_water_mat.set_shader_parameter("textured_water", true)
	_water_mat.render_priority = 1
	_river_mat = _make_material(OVERLAY_SHADER)
	_river_mat.render_priority = 2
	_border_mat = _make_material(OVERLAY_SHADER)
	_border_mat.render_priority = 3
	_improvement_meshes = ImprovementMeshes.build_all()

	for k in [-1, 0, 1]:
		var copy := Node3D.new()
		copy.name = "Copy%d" % (k + 1)
		copy.position.x = k * world_width
		add_child(copy)
		_copies.append(copy)
	_set_layer("water", TerrainMeshBuilder.build_water(map), _water_mat)
	_set_layer("rivers", TerrainMeshBuilder.build_rivers(map), _river_mat)
	refresh_geometry()


## Пересобирает то, что меняется по ходу игры. parts — набор из
## "terrain" (рельеф и леса), "improvements", "borders"; пустой — всё.
func refresh_geometry(parts: Dictionary = {}) -> void:
	var map := game.state.map
	var all := parts.is_empty()
	if all or parts.has("terrain"):
		_set_layer("terrain", TerrainMeshBuilder.build_terrain(map), _terrain_mat)
		refresh_landscape_models()
	if all or parts.has("improvements"):
		refresh_improvements()
	if all or parts.has("borders"):
		refresh_borders()
	if all or parts.has("roads"):
		refresh_roads()
	if viewer != null and (all or parts.has("terrain")):
		refresh_resources(viewer)


## Создаёт/обновляет слой в трёх копиях. res — Mesh или MultiMesh.
func _set_layer(layer_name: String, res: Resource, mat: Material, is_multimesh: bool = false) -> void:
	if not _layers.has(layer_name):
		var nodes := []
		for copy in _copies:
			var node: GeometryInstance3D
			if res is MultiMesh or is_multimesh:
				node = MultiMeshInstance3D.new()
			else:
				node = MeshInstance3D.new()
			node.name = layer_name
			node.material_override = mat
			copy.add_child(node)
			nodes.append(node)
		_layers[layer_name] = nodes
	for node in _layers[layer_name]:
		if node is MultiMeshInstance3D:
			node.multimesh = res
		else:
			node.mesh = res


func _make_material(shader: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("fog_tex", fog_texture)
	m.set_shader_parameter("reveal_all", reveal_all)
	_materials.append(m)
	return m


# --- Объекты на клетках -----------------------------------------------------------

## Одна копия импортированного меша на вариант, с сохранёнными LOD и UV.
func _landscape_mesh(id: String) -> ArrayMesh:
	if not _landscape_meshes.has(id):
		var original := LandscapeModels.mesh(id)
		if original == null:
			return null
		var mesh := original.duplicate() as ArrayMesh
		for surface in mesh.get_surface_count():
			var source := original.surface_get_material(surface) as StandardMaterial3D
			var material := _make_material(LANDSCAPE_SHADER)
			_copy_pbr(source, material)
			mesh.surface_set_material(surface, material)
		mesh.set_meta("source_asset", id)
		_landscape_meshes[id] = mesh
	return _landscape_meshes[id]


func _copy_pbr(source: StandardMaterial3D, material: ShaderMaterial) -> void:
	if source == null:
		return
	material.set_shader_parameter("base_color", source.albedo_color)
	material.set_shader_parameter("material_roughness", source.roughness)
	material.set_shader_parameter("has_texture", source.albedo_texture != null)
	material.set_shader_parameter("albedo_texture", source.albedo_texture)
	material.set_shader_parameter("has_normal", source.normal_enabled and source.normal_texture != null)
	material.set_shader_parameter("normal_texture", source.normal_texture)
	material.set_shader_parameter("normal_scale", source.normal_scale)
	material.set_shader_parameter("has_roughness", source.roughness_texture != null)
	material.set_shader_parameter("roughness_texture", source.roughness_texture)
	material.set_shader_parameter("roughness_channel", source.roughness_texture_channel)


func _refresh_massifs() -> void:
	var map := game.state.map
	if not _massif_plan.is_empty() and _massif_relief == map.relief and _massif_terrain == map.terrain:
		return
	var cfg: Dictionary = LandscapeModels.config()["mountain_massif"]
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(str(cfg["manifest"])))
	_massif_plan = MountainMassifs.build(map, cfg, manifest["footprint_axial"])
	_massif_relief = map.relief.duplicate()
	_massif_terrain = map.terrain.duplicate()
	var mask := ImageTexture.create_from_image(_massif_plan["image"])
	if _massif_mesh == null:
		var id: String = cfg["asset"]
		var original := LandscapeModels.mesh(id)
		# Импортные LOD строились до адаптации контура. Их редкие вершины дают
		# занавесы на склонах, поэтому здесь сохраняем исходную геометрию 45k.
		_massif_mesh = ArrayMesh.new()
		for surface in original.get_surface_count():
			_massif_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, original.surface_get_arrays(surface))
			var material := _make_material(MASSIF_SHADER)
			_copy_pbr(original.surface_get_material(surface) as StandardMaterial3D, material)
			material.set_shader_parameter("map_size", Vector2(map.width, map.height))
			material.set_shader_parameter("hex_size", MapStyle.HEX_SIZE)
			material.set_shader_parameter("edge_fade", float(cfg["edge_fade"]))
			material.set_shader_parameter("edge_albedo", load(str(cfg["edge_albedo"])))
			var rect: Array = cfg["fit_rect"]
			material.set_shader_parameter("fit_rect", Vector4(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3])))
			_massif_mesh.surface_set_material(surface, material)
		_massif_mesh.set_meta("source_asset", id)
	for surface in _massif_mesh.get_surface_count():
		_massif_mesh.surface_get_material(surface).set_shader_parameter("mountain_mask", mask)
	var items: Array = []
	for group in _massif_plan["groups"]:
		# Номер группы хранится как float32 в INSTANCE_CUSTOM, без цветового сжатия.
		items.append([group["transform"], Color.WHITE, Color(float(group["id"]), 1.0 if group["native"] else 0.0, 0, 0)])
	var mm := _new_multimesh(_massif_mesh, items.size())
	_fill(mm, items)
	_set_layer("mountain_massifs", mm, null)


func _landscape_item(items: Dictionary, group: String, tile: int, scale: float = 1.0,
		offset: Vector3 = Vector3.ZERO, salt: int = 0) -> void:
	var variants: Array = LandscapeModels.config()[group]
	var index := mini(variants.size() - 1, int(MapStyle.hash01(tile, salt + 220) * variants.size()))
	var id: String = variants[index]
	if not items.has(id):
		items[id] = []
	var rotation := MapStyle.hash01(tile, salt + 221) * TAU
	var basis := Basis(Vector3.UP, rotation).scaled(Vector3.ONE * scale)
	items[id].append([Transform3D(basis, _tile_pos(tile) + offset), Color.WHITE, _custom(tile)])


## Варианты выбираются по индексу тайла, без изменения состояния или ГПСЧ партии.
func refresh_landscape_models() -> void:
	var map := game.state.map
	var cfg := LandscapeModels.config()
	var items := {}
	for tile in map.size():
		if map.is_mountain(tile):
			continue
		if map.is_water(tile) or map.district[tile] != "":
			continue
		var feature := map.feature[tile]
		match feature:
			"WOODS", "RAINFOREST":
				var group := "jungle" if feature == "RAINFOREST" else \
					("conifers" if map.terrain[tile] in ["TUNDRA", "SNOW"] else "woods")
				_landscape_item(items, group, tile, float(cfg["forest_scale"]))
				if feature == "RAINFOREST" or tile % 7 == 0:
					_landscape_item(items, "jungle_detail" if feature == "RAINFOREST" else "woods_detail",
						tile, float(cfg["detail_scale"]), Vector3(0.35, 0, 0.3), 1)
			"MARSH":
				for patch in 3:
					var angle := float(patch) * TAU / 3.0
					_landscape_item(items, "marsh", tile, 0.8, Vector3(cos(angle), 0, sin(angle)) * 0.35, patch)
			"OASIS":
				for palm in 2:
					_landscape_item(items, "oasis", tile, 0.8, Vector3(-0.22 if palm == 0 else 0.22, 0, 0), palm)
			"GEOTHERMAL":
				_landscape_item(items, "geothermal", tile, 0.7)
			_:
				if map.is_hills(tile) and tile % 3 == 0:
					_landscape_item(items, "hill", tile, float(cfg["hill_scale"]))
	# Обновляем существующие слои тоже: удалённый лес получает ноль экземпляров.
	var ids := items.keys()
	for id in _landscape_meshes:
		if not ids.has(id):
			ids.append(id)
	ids.sort()
	for id in ids:
		var mesh := _landscape_mesh(id)
		if mesh == null:
			continue
		var instances: Array = items.get(id, [])
		var mm := _new_multimesh(mesh, instances.size())
		_fill(mm, instances)
		_set_layer("landscape_" + id, mm, null)
	_refresh_massifs()

func _new_multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm


func _tile_pos(i: int) -> Vector3:
	var map := game.state.map
	var p := map.grid.world_position(i, MapStyle.HEX_SIZE)
	return Vector3(p.x, MapStyle.tile_height(map, i), p.y)


func _custom(i: int) -> Color:
	var uv := TerrainMeshBuilder.tile_uv(game.state.map.grid, i)
	return Color(uv.x, uv.y, 0, 0)


## Плоские деревья из верхних двух рядов временного атласа. Варианты и позиции
## зависят только от индекса клетки, поэтому не меняются при обновлении карты.
func _build_forest_sprites(map: GameMap) -> MultiMesh:
	var items: Array = []
	for i in map.size():
		var feature := map.feature[i]
		if feature != "WOODS" and feature != "RAINFOREST":
			continue
		var base := _tile_pos(i)
		var variants := [0, 1, 2, 3, 5, 7, 8, 9, 10, 11]
		if feature == "RAINFOREST":
			variants = [6, 7, 9, 10, 11, 0]
		elif map.terrain[i] == "TUNDRA":
			variants = [4, 4, 1]
		var count := 3 if feature == "RAINFOREST" else 2
		for k in count:
			var choice := mini(variants.size() - 1, int(MapStyle.hash01(i, 80 + k) * variants.size()))
			var cell: int = variants[choice]
			var angle := (k + MapStyle.hash01(i, 90 + k) * 0.5) * TAU / count
			var radius := 0.12 + 0.2 * MapStyle.hash01(i, 100 + k)
			var scale := 0.82 + 0.28 * MapStyle.hash01(i, 110 + k)
			var pos := base + Vector3(cos(angle) * radius, 0.95 * scale * 0.5 - 0.03,
				sin(angle) * radius)
			var transform := Transform3D(Basis().scaled(Vector3.ONE * scale), pos)
			var tile_uv := TerrainMeshBuilder.tile_uv(map.grid, i)
			items.append([transform, Color.WHITE,
				Color(tile_uv.x, tile_uv.y, float(cell % 6) / 5.0, 0.0 if cell < 6 else 1.0)])
	var quad := QuadMesh.new()
	quad.size = Vector2(0.65, 0.95)
	var mm := _new_multimesh(quad, items.size())
	_fill(mm, items)
	return mm


## Низкий 3D лес: [лиственные кроны, хвойные кроны, стволы].
## Деревья занимают всю площадь гекса, но остаются существенно ниже юнитов.
func _build_trees(map: GameMap) -> Array:
	var crowns: Array = []
	var conifers: Array = []
	var trunks: Array = []
	for i in map.size():
		var f := map.feature[i]
		if f != "WOODS" and f != "RAINFOREST":
			continue
		var base := _tile_pos(i)
		var conifer := f == "WOODS" and (map.terrain[i] == "TUNDRA" or map.terrain[i] == "SNOW")
		var count := 18 if f == "RAINFOREST" else 14
		for k in count:
			var ang := k * 2.39996 + MapStyle.hash01(i, 40) * TAU
			var r := 0.73 * sqrt((float(k) + 0.5) / count)
			var pos := base + Vector3(cos(ang) * r, 0, sin(ang) * r)
			var s := 0.8 + MapStyle.hash01(i, 60 + k) * 0.35
			var palette: Array[Color] = [Color("568346"), Color("668846"), Color("7e994d"), Color("4f7743")]
			if f == "RAINFOREST":
				palette = MapStyle.RAINFOREST_COLORS
			elif conifer:
				palette = MapStyle.CONIFER_COLORS
			var col: Color = palette[int(MapStyle.hash01(i, 70 + k) * palette.size()) % palette.size()]
			var pine := conifer or (f == "WOODS" and k % 3 != 0)
			var crown_basis := Basis().scaled(Vector3(s, s, s))
			if pine:
				for tier in 3:
					var size := s * (1.0 - float(tier) * 0.24)
					var tier_basis := Basis().scaled(Vector3.ONE * size)
					conifers.append([Transform3D(tier_basis, pos + Vector3(0, (0.12 + tier * 0.055) * s, 0)),
						col.lightened(0.035 * tier), _custom(i)])
			else:
				crowns.append([Transform3D(crown_basis, pos + Vector3(0, 0.15 * s, 0)), col, _custom(i)])
			trunks.append([Transform3D(Basis().scaled(Vector3.ONE * s), pos + Vector3(0, 0.045 * s, 0)), MapStyle.TRUNK_COLOR, _custom(i)])
	var crown_mesh := SphereMesh.new()
	crown_mesh.radius = 0.11
	crown_mesh.height = 0.17
	crown_mesh.radial_segments = 8
	crown_mesh.rings = 4
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.012
	trunk_mesh.bottom_radius = 0.018
	trunk_mesh.height = 0.09
	trunk_mesh.radial_segments = 5
	var mm_c := _new_multimesh(crown_mesh, crowns.size())
	_fill(mm_c, crowns)
	var pine_mesh := CylinderMesh.new()
	pine_mesh.top_radius = 0.0
	pine_mesh.bottom_radius = 0.105
	pine_mesh.height = 0.15
	pine_mesh.radial_segments = 7
	var mm_p := _new_multimesh(pine_mesh, conifers.size())
	_fill(mm_p, conifers)
	var mm_t := _new_multimesh(trunk_mesh, trunks.size())
	_fill(mm_t, trunks)
	return [mm_c, mm_p, mm_t]


## Маркеры ресурсов зависят от технологий игрока (стратегические скрыты).
func refresh_resources(player: Player) -> void:
	var map := game.state.map
	var items: Array = []
	for i in map.size():
		if not reveal_all and not player.is_revealed(i):
			continue
		var ids: Array[String] = []
		var rid := map.resource[i]
		if rid != "" and (reveal_all or Yields.resource_visible(game.data, rid, player)):
			ids.append(rid)
		for k in ids.size():
			var index := NatureFlags.index(ids[k])
			if index < 0:
				continue
			var pos := _tile_pos(i)
			pos.y = MapStyle.WATER_Y if map.is_water(i) else pos.y
			pos += Vector3(0.32, 0.45, 0.18)
			var custom := _custom(i)
			custom.b = float(index) / 63.0
			items.append([Transform3D(Basis(), pos), Color.WHITE, custom])
	var quad := QuadMesh.new()
	quad.size = Vector2(0.24, 0.30)
	var mm := _new_multimesh(quad, items.size())
	_fill(mm, items)
	_set_layer("nature_flags", mm, _flag_mat)
	for node in _layers["nature_flags"]:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Улучшения клеток: по слою на каждую деталь каждого типа.
func refresh_improvements() -> void:
	var map := game.state.map
	var per_part := {}   # "IMP#k" -> [items]
	for i in map.size():
		var imp := map.improvement[i]
		if imp == "" or not _improvement_meshes.has(imp):
			continue
		var base := _tile_pos(i)
		if map.is_water(i):
			base.y = MapStyle.WATER_Y
		var rot := Basis(Vector3.UP, MapStyle.hash01(i, 90) * TAU)
		var parts: Array = _improvement_meshes[imp]
		for k in parts.size():
			var part: Dictionary = parts[k]
			var key := "%s#%d" % [imp, k]
			if not per_part.has(key):
				per_part[key] = []
			for local in part["transforms"]:
				var t: Transform3D = local
				var world := Transform3D(rot * t.basis, base + rot * t.origin + Vector3(-0.1, 0, -0.05))
				var col: Color = part["color"]
				if map.pillaged[i] == 1:
					col = col.darkened(0.6)   # разграблено
				per_part[key].append([world, col, _custom(i)])
	for imp in _improvement_meshes:
		var parts: Array = _improvement_meshes[imp]
		for k in parts.size():
			var key := "%s#%d" % [imp, k]
			var items: Array = per_part.get(key, [])
			var mm := _new_multimesh(parts[k]["mesh"], items.size())
			_fill(mm, items)
			_set_layer("imp_" + key, mm, _feature_mat)


## Дороги: полосы между центрами соседних клеток с дорогой (и «пятачок» в клетке).
func refresh_roads() -> void:
	var map := game.state.map
	var grid := map.grid
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 0
	var col := Color("9c8463")
	for i in map.size():
		if map.road[i] == 0:
			continue
		var c2 := grid.world_position(i, MapStyle.HEX_SIZE)
		var h := MapStyle.tile_height(map, i) + 0.02
		var uv := TerrainMeshBuilder.tile_uv(grid, i)
		var lvl_col := col.lightened(0.08 * map.road[i])
		var links := 0
		for d in 6:
			var nb := grid.neighbor(i, d)
			if nb < 0 or map.road[nb] == 0:
				continue
			links += 1
			# Половина отрезка до середины ребра — вторую половину нарисует сосед.
			var mid := c2 + (HexGrid.corner_offset(d, MapStyle.HEX_SIZE) + HexGrid.corner_offset((d + 1) % 6, MapStyle.HEX_SIZE)) * 0.5
			var along := (mid - c2).normalized()
			var across := Vector2(-along.y, along.x) * 0.07
			var pts := [Vector3(c2.x + across.x, h, c2.y + across.y), Vector3(mid.x + across.x, h, mid.y + across.y),
				Vector3(mid.x - across.x, h, mid.y - across.y), Vector3(c2.x - across.x, h, c2.y - across.y)]
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_color(lvl_col)
				st.set_uv2(uv)
				st.set_normal(Vector3.UP)
				st.add_vertex(pts[idx])
			count += 1
		# Пятачок в центре клетки.
		for kk in 6:
			var a := c2 + HexGrid.corner_offset(kk, 0.12)
			var b := c2 + HexGrid.corner_offset((kk + 1) % 6, 0.12)
			for p in [Vector3(c2.x, h, c2.y), Vector3(a.x, h, a.y), Vector3(b.x, h, b.y)]:
				st.set_color(lvl_col)
				st.set_uv2(uv)
				st.set_normal(Vector3.UP)
				st.add_vertex(p)
		count += 1
	_set_layer("roads", st.commit() if count > 0 else null, _river_mat)


## Границы держав: цветная полоса вдоль рёбер, где сосед не принадлежит той же державе.
func refresh_borders() -> void:
	var map := game.state.map
	var grid := map.grid
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 0
	for i in map.size():
		var cid := map.owner_city[i]
		if cid < 0:
			continue
		var owner_id := game.state.city(cid).owner
		var col := game.state.player(owner_id).color
		var c2 := grid.world_position(i, MapStyle.HEX_SIZE)
		var h := maxf(MapStyle.tile_height(map, i), MapStyle.WATER_Y) + 0.03
		var uv := TerrainMeshBuilder.tile_uv(grid, i)
		for d in 6:
			var nb := grid.neighbor(i, d)
			var other := -1
			if nb >= 0 and map.owner_city[nb] >= 0:
				other = game.state.city(map.owner_city[nb]).owner
			if other == owner_id:
				continue
			var a := c2 + HexGrid.corner_offset(d, MapStyle.HEX_SIZE)
			var b := c2 + HexGrid.corner_offset((d + 1) % 6, MapStyle.HEX_SIZE)
			var ai := c2 + (a - c2) * 0.84
			var bi := c2 + (b - c2) * 0.84
			var pts := [Vector3(a.x, h, a.y), Vector3(b.x, h, b.y), Vector3(bi.x, h, bi.y), Vector3(ai.x, h, ai.y)]
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_color(Color(col.r, col.g, col.b, 0.9))
				st.set_uv2(uv)
				st.set_normal(Vector3.UP)
				st.add_vertex(pts[idx])
			count += 1
	_set_layer("borders", st.commit() if count > 0 else null, _border_mat)


func _fill(mm: MultiMesh, items: Array) -> void:
	for k in items.size():
		mm.set_instance_transform(k, items[k][0])
		mm.set_instance_color(k, items[k][1])
		mm.set_instance_custom_data(k, items[k][2])


# --- Туман войны ----------------------------------------------------------------------

func refresh_fog(player: Player) -> void:
	viewer = player
	var map := game.state.map
	for i in map.size():
		var v := 0.0
		if player.is_visible(i):
			v = 1.0
		elif player.is_revealed(i):
			v = 0.5
		fog_image.set_pixel(map.grid.col_of(i), map.grid.row_of(i), Color(v, 0, 0, 1))
	fog_texture.update(fog_image)


func set_reveal_all(value: bool) -> void:
	reveal_all = value
	for m in _materials:
		m.set_shader_parameter("reveal_all", value)


# --- Координаты -------------------------------------------------------------------------

## Позиция центра клетки на общей плоскости, в копии, ближайшей к точке near_x.
func tile_world(i: int, near_x: float = INF) -> Vector3:
	var p := _tile_pos(i)
	if map_is_water(i):
		p.y = MapStyle.WATER_Y
	if not reveal_all and viewer != null and not viewer.is_revealed(i):
		p.y = MapStyle.H_FLAT   # разведанная карта и пелена имеют общий уровень
	if near_x != INF:
		p.x += round((near_x - p.x) / world_width) * world_width
	return p


func map_is_water(i: int) -> bool:
	return game.state.map.is_water(i)


## Клетка под лучом камеры (с учётом высоты террас). -1 — мимо карты.
func pick_tile(origin: Vector3, dir: Vector3) -> int:
	if absf(dir.y) < 1e-4:
		return -1
	var grid := game.state.map.grid
	var y := 0.0
	var tile := -1
	# Несколько итераций: пересекаем плоскость, уточняем по высоте найденной клетки.
	for _iter in 3:
		var t := (y - origin.y) / dir.y
		if t < 0:
			return -1
		var hit := origin + dir * t
		var x := fposmod(hit.x, world_width)
		tile = grid.index_at_world(x, hit.z, MapStyle.HEX_SIZE)
		if tile < 0:
			return -1
		var ny := tile_world(tile).y
		if absf(ny - y) < 0.01:
			break
		y = ny
	return tile
