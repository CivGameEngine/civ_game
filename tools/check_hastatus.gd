extends SceneTree
## Импорт, состав и отсутствие текстур. --preview сохраняет рендер Godot.
const BASE := "res://art/units/rome/hastatus_v1/"
var _errors: PackedStringArray = []
var _preview := false
var _frames := 0
var _triangles := 0
var _meshes := 0
var _bounds := AABB()

func _initialize() -> void:
	call_deferred("_check")

func _check() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BASE + "manifest.json"))
	var bytes := FileAccess.get_file_as_bytes(BASE + str(manifest["model"]))
	var json_size := bytes.decode_u32(12)
	var doc: Dictionary = JSON.parse_string(bytes.slice(20, 20 + json_size).get_string_from_utf8())
	_expect(doc.get("images", []).is_empty() and doc.get("textures", []).is_empty(), "В экспорт попали текстуры")
	_expect(doc.get("skins", []).is_empty() and doc.get("animations", []).is_empty(), "Ожидалась статическая модель")
	_expect(doc.get("cameras", []).is_empty(), "Студийная камера попала в GLB")
	var packed := load(BASE + str(manifest["model"])) as PackedScene
	if packed == null:
		push_error("Модель гастата не импортирована")
		quit(1)
		return
	var instance := packed.instantiate()
	_walk(instance, Transform3D.IDENTITY)
	instance.free()
	_expect(_meshes == manifest["export_parts"].size(), "Не совпадает состав частей модели")
	_expect(_meshes == 8, "В экспорте должны быть восемь групп без студийных объектов")
	_expect(_triangles == int(manifest["export_triangles"]), "Не совпадает число треугольников")
	_expect(_bounds.size.y > 2.6 and _bounds.size.y < 2.8, "Неверные оси или масштаб по высоте")
	_expect(_bounds.position.y > -0.02 and _bounds.position.y < 0.05, "Основание не у стоп")
	_expect(_bounds.size.x > 1.3 and _bounds.size.x < 1.7, "Неверная ширина со щитом")
	for message in _errors:
		push_error(message)
	print("Гастат: %d частей, %d треугольников; ошибок: %d" % [_meshes, _triangles, _errors.size()])
	_preview = OS.get_cmdline_user_args().has("--preview") and _errors.is_empty()
	if not _preview:
		quit(0 if _errors.is_empty() else 1)
		return
	root.size = Vector2i(1200, 1700)
	var scene: Node3D = load(BASE + "preview.tscn").instantiate()
	root.add_child(scene)

func _walk(node: Node, parent_transform: Transform3D) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform *= node.transform
	if node is MeshInstance3D:
		var bounds: AABB = transform * node.mesh.get_aabb()
		_bounds = bounds if _meshes == 0 else _bounds.merge(bounds)
		_meshes += 1
		for surface in node.mesh.get_surface_count():
			var mat := node.mesh.surface_get_material(surface) as StandardMaterial3D
			_expect(mat != null, "Нет нейтрального материала")
			if mat != null:
				_expect(mat.albedo_texture == null and mat.normal_texture == null and mat.roughness_texture == null, "Материал содержит текстуры")
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				if not vertex.is_finite():
					_expect(false, "Повреждённая вершина")
					break
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			_triangles += indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
	for child in node.get_children():
		_walk(child, transform)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_errors.append(message)

func _process(_delta: float) -> bool:
	if _preview:
		_frames += 1
		if _frames == 30:
			var error := root.get_texture().get_image().save_png(BASE + "previews/hastatus_godot.png")
			print("Рендер Godot: ", error_string(error))
			quit(0 if error == OK else 1)
	return false
