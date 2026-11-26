class_name DistrictsView
extends Node3D
## Районы на карте: цветная площадка, простая постройка по типу (data/districts.json: color, look),
## леса при строительстве и табличка с названием. Значок ✿ — действует «Урбанизация Нерона».
## Временная графика — до моделей художника.

var game: Game
var map_view: MapView
var _nodes := {}        # tile -> Node3D
var _signature := {}    # tile -> строка состояния
var _mats := {}
const STONE := Color("e9e1cf")


func setup(g: Game, mv: MapView) -> void:
	game = g
	map_view = mv
	for c in get_children():
		c.queue_free()
	_nodes.clear()
	_signature.clear()


func _mat(c: Color, alpha: float = 1.0) -> StandardMaterial3D:
	var key := "%s|%.2f" % [c.to_html(), alpha]
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(c, alpha)
		m.roughness = 0.9
		if alpha < 1.0:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mats[key] = m
	return _mats[key]


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, alpha: float = 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color, alpha)
	mi.position = pos + Vector3(0, size.y / 2.0, 0)
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, top: float, bottom: float, h: float, pos: Vector3, color: Color, seg: int = 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = top
	cm.bottom_radius = bottom
	cm.height = h
	cm.radial_segments = seg
	mi.mesh = cm
	mi.material_override = _mat(color)
	mi.position = pos + Vector3(0, h / 2.0, 0)
	parent.add_child(mi)
	return mi


func _dome(parent: Node3D, r: float, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r
	sm.is_hemisphere = true
	sm.radial_segments = 12
	sm.rings = 4
	mi.mesh = sm
	mi.material_override = _mat(color)
	mi.position = pos
	parent.add_child(mi)


## Постройка района: форма по look, размер растёт с уровнем и числом зданий.
func _structure(root: Node3D, look: String, color: Color, tier: int, nb: int) -> void:
	var s := 1.0 + 0.15 * (tier - 1)
	match look:
		"dome":
			_cyl(root, 0.2 * s, 0.22 * s, 0.14 * s, Vector3.ZERO, STONE)
			_dome(root, 0.17 * s, Vector3(0, 0.14 * s, 0), color)
		"columns":
			_box(root, Vector3(0.46, 0.04, 0.32) * s, Vector3.ZERO, STONE)
			for i in 5:
				for z in [-0.11, 0.11]:
					_cyl(root, 0.022, 0.022, 0.2 * s, Vector3((-0.18 + i * 0.09) * s, 0.04 * s, z * s), STONE, 6)
			var roof := MeshInstance3D.new()
			var pm := PrismMesh.new()
			pm.size = Vector3(0.5, 0.1, 0.34) * s
			roof.mesh = pm
			roof.material_override = _mat(color)
			roof.position = Vector3(0, 0.29 * s, 0)
			root.add_child(roof)
		"walls":
			for k in 4:
				var a := k * PI / 2.0
				var w := _box(root, Vector3(0.5, 0.12, 0.05) * s, Vector3(cos(a), 0, sin(a)) * 0.24 * s, color)
				w.rotation.y = a + PI / 2.0
			_box(root, Vector3(0.14, 0.24, 0.14) * s, Vector3.ZERO, STONE)
		"pier":
			_box(root, Vector3(0.62, 0.05, 0.12), Vector3(0, 0, 0.05), Color("8a6b4a"))
			_box(root, Vector3(0.12, 0.05, 0.44), Vector3(0.2, 0, -0.1), Color("8a6b4a"))
			_box(root, Vector3(0.18, 0.16, 0.16) * s, Vector3(-0.18, 0.05, -0.12), color)
			_cyl(root, 0.035, 0.05, 0.34 * s, Vector3(0.25, 0.05, 0.22), STONE, 8)
		"block":
			_box(root, Vector3(0.42, 0.12, 0.42) * s, Vector3.ZERO, STONE)
			_box(root, Vector3(0.26, 0.12, 0.26) * s, Vector3(0, 0.12 * s, 0), color)
		"arena_half", "arena":
			var full := look == "arena"
			var ring := _cyl(root, 0.27 * s, 0.3 * s, 0.14 * s, Vector3.ZERO, color, 16)
			if not full:
				ring.scale = Vector3(1, 1, 0.6)
			_cyl(root, 0.18 * s, 0.18 * s, 0.15 * s, Vector3.ZERO, Color("c8b48a"), 16).scale = Vector3(1, 1, 0.6 if not full else 1.0)
		"tower":
			_box(root, Vector3(0.4, 0.14, 0.3) * s, Vector3(-0.04, 0, 0), color)
			_cyl(root, 0.05, 0.06, 0.42 * s, Vector3(0.18, 0, 0.08), Color("6c5a4a"), 8)
		"arches":
			for i in 3:
				var x := -0.24 + i * 0.24
				_box(root, Vector3(0.06, 0.26, 0.08), Vector3(x, 0, 0), color)
			_box(root, Vector3(0.6, 0.06, 0.1), Vector3(0, 0.26, 0), color)
		"wall":
			_box(root, Vector3(0.66, 0.2, 0.12), Vector3.ZERO, color)
		"houses", "villa":
			var n := 4 + nb + tier
			for k in n:
				var a := k * 2.1 + 0.4
				var r := 0.08 + 0.05 * k
				var p := Vector3(cos(a) * r, 0, sin(a) * r)
				var hs := 0.12 if look == "houses" else 0.17
				_box(root, Vector3(hs, hs * 0.8 * (1.0 + 0.3 * (tier - 1)), hs), p, STONE)
				var roof2 := MeshInstance3D.new()
				var rm := PrismMesh.new()
				rm.size = Vector3(hs * 1.15, hs * 0.55, hs * 1.05)
				roof2.mesh = rm
				roof2.material_override = _mat(color.darkened(0.15))
				roof2.position = p + Vector3(0, hs * 0.8 * (1.0 + 0.3 * (tier - 1)) + hs * 0.27, 0)
				root.add_child(roof2)
		"runway":
			_box(root, Vector3(0.72, 0.02, 0.14), Vector3.ZERO, Color("4a4f57"))
			_box(root, Vector3(0.16, 0.14, 0.16), Vector3(0, 0.02, 0.2), color)
		_:
			_box(root, Vector3(0.3, 0.16, 0.3) * s, Vector3.ZERO, color)
	# Здания района — маленькие пристройки по кругу.
	if look != "houses" and look != "villa":
		for k in nb:
			var a2 := 0.6 + k * 1.3
			_box(root, Vector3(0.09, 0.09, 0.09), Vector3(cos(a2), 0, sin(a2)) * 0.33, STONE)


func _build_node(city: City, d: Dictionary) -> Node3D:
	var root := Node3D.new()
	var def := DistrictRules.ddef(game, d["type"])
	var color := Color(def.get("color", "aaaaaa"))
	var owner_p := game.state.player(city.owner)
	# Площадка-шестиугольник в цвете района с каймой цвета державы.
	var plate := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.72 * MapStyle.HEX_SIZE
	pm.bottom_radius = 0.76 * MapStyle.HEX_SIZE
	pm.height = 0.03
	pm.radial_segments = 6
	plate.mesh = pm
	plate.material_override = _mat(color.lerp(Color("cfc6b2"), 0.55), 1.0 if d["complete"] else 0.75)
	plate.rotation.y = 0.0
	plate.position = Vector3(0, 0.015, 0)
	root.add_child(plate)
	var rim := MeshInstance3D.new()
	var rmesh := CylinderMesh.new()
	rmesh.top_radius = 0.79 * MapStyle.HEX_SIZE
	rmesh.bottom_radius = 0.8 * MapStyle.HEX_SIZE
	rmesh.height = 0.02
	rmesh.radial_segments = 6
	rim.mesh = rmesh
	rim.material_override = _mat(owner_p.color.darkened(0.2))
	rim.rotation.y = 0.0
	root.add_child(rim)
	var body := Node3D.new()
	body.position = Vector3(0, 0.03, 0)
	root.add_child(body)
	if d["complete"]:
		_structure(body, def.get("look", ""), color, int(d["tier"]), d["buildings"].size())
	else:
		# Стройка: полупрозрачный объём в лесах.
		_box(body, Vector3(0.36, 0.2, 0.36), Vector3.ZERO, color, 0.35)
		for x in [-0.2, 0.2]:
			for z in [-0.2, 0.2]:
				_box(body, Vector3(0.025, 0.3, 0.025), Vector3(x, 0, z), Color("8a6b4a"))
		_box(body, Vector3(0.44, 0.02, 0.02), Vector3(0, 0.22, -0.2), Color("8a6b4a"))
		_box(body, Vector3(0.44, 0.02, 0.02), Vector3(0, 0.22, 0.2), Color("8a6b4a"))
	var label := Label3D.new()
	var name := DistrictRules.display_name(game, city.owner, d["type"], int(d["tier"]))
	var nero := DistrictRules.nero(game, city, d)
	if not nero.is_empty():
		name = "✿ " + name
	if not d["complete"]:
		name += " (стройка)"
	label.text = name
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.pixel_size = 0.004
	label.outline_size = 10
	label.modulate = Color(0.75, 1.0, 0.65) if not nero.is_empty() else Color(1, 1, 1, 0.95)
	label.outline_modulate = owner_p.color.darkened(0.6)
	label.no_depth_test = true
	label.position = Vector3(0, 0.62, 0.15)
	root.add_child(label)
	add_child(root)
	return root


func refresh(viewer: Player, cam_x: float) -> void:
	var alive := {}
	for cid in game.state.cities:
		var city: City = game.state.cities[cid]
		for d in city.districts:
			var tile := int(d["tile"])
			alive[tile] = true
			var nero := DistrictRules.nero(game, city, d)
			var sig := "%s|%d|%s|%d|%d|%d" % [d["type"], int(d["tier"]), str(d["complete"]), d["buildings"].size(),
				city.owner, 0 if nero.is_empty() else int(float(nero["bonus"]) * 100)]
			if _signature.get(tile, "") != sig and _nodes.has(tile):
				_nodes[tile].queue_free()
				_nodes.erase(tile)
			if not _nodes.has(tile):
				_nodes[tile] = _build_node(city, d)
				_signature[tile] = sig
			var node: Node3D = _nodes[tile]
			node.visible = map_view.reveal_all or viewer.is_revealed(tile)
			node.position = map_view.tile_local(tile, cam_x)
	for tile in _nodes.keys():
		if not alive.has(tile):
			_nodes[tile].queue_free()
			_nodes.erase(tile)
			_signature.erase(tile)
