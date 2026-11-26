class_name CitiesView
extends Node3D
## Города на карте: домики (их число растёт с населением) и табличка с названием.
## Временная графика — до скетчей художника.

var game: Game
var map_view: MapView
var _nodes := {}        # city id -> Node3D
var _signature := {}    # city id -> строка состояния, чтобы не пересобирать без нужды
var _mats := {}


func setup(g: Game, mv: MapView) -> void:
	game = g
	map_view = mv
	for c in get_children():
		c.queue_free()
	_nodes.clear()
	_signature.clear()


func _mat(c: Color) -> StandardMaterial3D:
	var key := c.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.95
		_mats[key] = m
	return _mats[key]


func _house(parent: Node3D, pos: Vector3, scale: float, roof: Color) -> void:
	var walls := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.16, 0.12, 0.14) * scale
	walls.mesh = bm
	walls.material_override = _mat(Color("e9dcc0"))
	walls.position = pos + Vector3(0, 0.06 * scale, 0)
	parent.add_child(walls)
	var r := MeshInstance3D.new()
	var rm := PrismMesh.new()
	rm.size = Vector3(0.19, 0.09, 0.16) * scale
	r.mesh = rm
	r.material_override = _mat(roof)
	r.position = pos + Vector3(0, 0.165 * scale, 0)
	parent.add_child(r)


func _build_city_node(city: City, viewer: Player) -> Node3D:
	var root := Node3D.new()
	var owner_p := game.state.player(city.owner)
	var roof := owner_p.color.darkened(0.15)
	var houses := mini(3 + city.population, 14)
	# Домики по спирали вокруг центра клетки.
	for k in houses:
		var a := k * 2.4
		var r := 0.12 + 0.045 * k
		var pos := Vector3(cos(a) * r, 0, sin(a) * r)
		var s := 1.0 + MapStyle.hash01(city.id * 31 + k) * 0.35
		_house(root, pos, s, roof)
	if city.is_capital:
		var tower := MeshInstance3D.new()
		var tm := CylinderMesh.new()
		tm.top_radius = 0.07
		tm.bottom_radius = 0.09
		tm.height = 0.42
		tm.radial_segments = 8
		tower.mesh = tm
		tower.material_override = _mat(Color("efe6d2"))
		tower.position = Vector3(0, 0.21, 0)
		root.add_child(tower)
		var cap := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = 0.1
		cm.height = 0.16
		cm.radial_segments = 8
		cap.mesh = cm
		cap.material_override = _mat(owner_p.color)
		cap.position = Vector3(0, 0.5, 0)
		root.add_child(cap)
	var label := Label3D.new()
	var star := "★ " if city.is_capital else ""
	var text := "%s%d  %s" % [star, city.population, city.name]
	var hp_max := int(game.data.const_value("city_hp", 200))
	if city.hp < hp_max or city.wall_hp > 0:
		text += "\n♥%d%s" % [city.hp, ("  ▣%d" % city.wall_hp) if city.wall_hp > 0 else ""]
	if city.owner == viewer.id:
		var item := city.current_item()
		if item.is_empty():
			text += "\n(не выбрано производство)"
		else:
			var t := CityRules.turns_to_build(game, city, item)
			text += "\n%s · %s" % [CityRules.item_name(game, item, city.owner), str(t) if t > 0 else "∞"]
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 56
	label.pixel_size = 0.0045
	label.outline_size = 14
	label.modulate = Color.WHITE
	label.outline_modulate = owner_p.color.darkened(0.55)
	label.no_depth_test = true
	label.position = Vector3(0, 0.95, 0)
	root.add_child(label)
	add_child(root)
	return root


func refresh(viewer: Player, cam_x: float) -> void:
	var alive := {}
	for cid in game.state.cities:
		var city: City = game.state.cities[cid]
		alive[cid] = true
		var sig := "%d|%d|%s|%s|%d|%d|%d" % [city.population, city.owner, str(city.queue), str(city.progress), viewer.id, city.hp, city.wall_hp]
		if _signature.get(cid, "") != sig and _nodes.has(cid):
			_nodes[cid].queue_free()
			_nodes.erase(cid)
		if not _nodes.has(cid):
			_nodes[cid] = _build_city_node(city, viewer)
			_signature[cid] = sig
		var node: Node3D = _nodes[cid]
		node.visible = map_view.reveal_all or viewer.is_revealed(city.tile)
		node.position = map_view.tile_local(city.tile, cam_x)
	for cid in _nodes.keys():
		if not alive.has(cid):
			_nodes[cid].queue_free()
			_nodes.erase(cid)
			_signature.erase(cid)
