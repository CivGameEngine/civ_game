class_name UnitsView
extends Node3D
## Фигурки юнитов. Временная графика из примитивов — заменится артами.
## Юнит виден, только если его клетку видит текущий игрок.

var game: Game
var map_view: MapView
var _nodes := {}   # unit id -> Node3D
var _materials := {}
var selected_id := -1
var _selection_ring: MeshInstance3D


func setup(g: Game, mv: MapView) -> void:
	game = g
	map_view = mv
	for c in get_children():
		c.queue_free()
	_nodes.clear()
	_selection_ring = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.36
	ring.outer_radius = 0.44
	ring.rings = 24
	ring.ring_segments = 6
	_selection_ring.mesh = ring
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(1.0, 0.92, 0.45)
	rm.emission_enabled = true
	rm.emission = Color(1.0, 0.85, 0.3)
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_selection_ring.material_override = rm
	_selection_ring.scale = Vector3(1, 0.4, 1)
	_selection_ring.visible = false
	add_child(_selection_ring)


func _mat(c: Color) -> StandardMaterial3D:
	var key := c.to_html()
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.9
		_materials[key] = m
	return _materials[key]


func _make_unit_node(u: Unit) -> Node3D:
	var root := Node3D.new()
	var owner_color := game.state.player(u.owner).color
	var layer := Movement.layer(game, u.type)
	var cls: String = game.data.unit_def(u.type).get("class", "")
	# Подставка цвета державы.
	var base := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.26
	bm.bottom_radius = 0.3
	bm.height = 0.05
	bm.radial_segments = 16
	base.mesh = bm
	base.material_override = _mat(owner_color)
	base.position.y = 0.025
	root.add_child(base)
	# Тело.
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.09
	cm.height = 0.36
	cm.radial_segments = 10
	cm.rings = 3
	body.mesh = cm
	body.material_override = _mat(owner_color.lightened(0.25) if layer == "CIVILIAN" else owner_color.darkened(0.1))
	body.position.y = 0.23
	root.add_child(body)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.07
	hm.height = 0.14
	hm.radial_segments = 10
	hm.rings = 5
	head.mesh = hm
	head.material_override = _mat(Color("e9c9a4"))
	head.position.y = 0.48
	root.add_child(head)
	if Army.is_commander(game, u) or not u.commander.is_empty():
		# Знамя командующего: шест с полотнищем цвета державы.
		var pole := MeshInstance3D.new()
		var pm2 := CylinderMesh.new()
		pm2.top_radius = 0.008
		pm2.bottom_radius = 0.01
		pm2.height = 0.8
		pm2.radial_segments = 4
		pole.mesh = pm2
		pole.material_override = _mat(Color("5a4030"))
		pole.position = Vector3(-0.13, 0.4, 0)
		root.add_child(pole)
		var flag := MeshInstance3D.new()
		var fm := BoxMesh.new()
		fm.size = Vector3(0.18, 0.12, 0.01)
		flag.mesh = fm
		flag.material_override = _mat(owner_color.lightened(0.1))
		flag.position = Vector3(-0.04, 0.72, 0)
		root.add_child(flag)
	if layer == "COMBAT":
		var spear := MeshInstance3D.new()
		var sm := CylinderMesh.new()
		sm.top_radius = 0.01
		sm.bottom_radius = 0.012
		sm.height = 0.62
		sm.radial_segments = 4
		spear.mesh = sm
		spear.material_override = _mat(Color("6b4a32"))
		spear.position = Vector3(0.12, 0.33, 0)
		root.add_child(spear)
		if cls == "RECON":
			spear.scale = Vector3(1, 0.6, 1)
	else:
		# Поклажа поселенца/строителя.
		var pack := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.14, 0.14, 0.1)
		pack.mesh = pm
		pack.material_override = _mat(Color("a0784e"))
		pack.position = Vector3(0, 0.26, 0.1)
		root.add_child(pack)
	var info := Label3D.new()
	info.name = "Info"
	info.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	info.font_size = 40
	info.pixel_size = 0.004
	info.outline_size = 10
	info.no_depth_test = true
	info.position = Vector3(0, 0.75, 0)
	root.add_child(info)
	root.scale = Vector3.ONE * 1.3
	add_child(root)
	return root


## Синхронизирует фигурки с состоянием игры. cam_x — для выбора копии карты.
func refresh(viewer: Player, cam_x: float) -> void:
	var alive := {}
	for id in game.state.units:
		var u: Unit = game.state.units[id]
		alive[id] = true
		var look := "%s|%d" % [u.type, int(not u.commander.is_empty())]
		if _nodes.has(id) and _nodes[id].get_meta("look", "") != look:
			_nodes[id].queue_free()
			_nodes.erase(id)
		if not _nodes.has(id):
			_nodes[id] = _make_unit_node(u)
			_nodes[id].set_meta("look", look)
		var node: Node3D = _nodes[id]
		var visible_now := map_view.reveal_all or viewer.is_visible(u.tile) or u.owner == viewer.id
		node.visible = visible_now
		if visible_now:
			node.position = _unit_pos(u, cam_x)
			var info: Label3D = node.get_node("Info")
			var txt := ""
			if u.hp < 100:
				txt = "♥%d" % u.hp
			if u.owner == viewer.id and Combat.can_promote(u) and Combat.can_attack(game, u):
				txt += " ★"
			info.text = txt
			info.modulate = Color(1.0, 0.45, 0.4) if u.hp < 40 else Color(1, 1, 1)
	for id in _nodes.keys():
		if not alive.has(id):
			_nodes[id].queue_free()
			_nodes.erase(id)
	var sel: Unit = game.state.unit(selected_id)
	_selection_ring.visible = sel != null
	if sel != null:
		_selection_ring.position = _unit_pos(sel, cam_x) + Vector3(0, 0.03, 0)


func _unit_pos(u: Unit, cam_x: float) -> Vector3:
	var p := map_view.tile_local(u.tile, cam_x)
	# Гражданский и боевой в одной клетке стоят рядом.
	if game.state.units_at(u.tile).size() > 1:
		p.x += -0.22 if Movement.layer(game, u.type) == "CIVILIAN" else 0.2
	return p
