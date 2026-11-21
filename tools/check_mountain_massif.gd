extends SceneTree
## Проверка отдельного горного массива. --preview дополнительно сохраняет рендер Godot.
const BASE := "res://art/landscape/massifs/"
var _frames := 0
var _preview := false
var _errors: PackedStringArray = []

func _initialize() -> void:
	call_deferred("_check")

func _check() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BASE + "manifest.json"))
	var packed := load(BASE + str(manifest["model"])) as PackedScene
	if packed == null:
		push_error("Горный массив не импортирован")
		quit(1)
		return
	var instance := packed.instantiate()
	var meshes: Array[MeshInstance3D] = []
	_collect(instance, meshes)
	_expect(meshes.size() == 1, "В экспорт попали посторонние объекты")
	var triangles := 0
	for object in meshes:
		_expect(object.transform.is_equal_approx(Transform3D.IDENTITY), "Изменён масштаб или положение")
		var bounds := object.mesh.get_aabb()
		var source_bounds: Dictionary = manifest["bounds_export_blender_z_up"]
		var lo: Array = source_bounds["min"]
		var hi: Array = source_bounds["max"]
		var expected := Vector3(float(hi[0]) - float(lo[0]), float(hi[2]) - float(lo[2]), float(hi[1]) - float(lo[1]))
		_expect(bounds.size.distance_to(expected) < 0.01, "Неверные оси или размеры")
		_expect(absf(bounds.position.y) < 0.001, "Основание не на общей плоскости Y=0")
		for surface in object.mesh.get_surface_count():
			var mat := object.mesh.surface_get_material(surface) as StandardMaterial3D
			_expect(mat != null and mat.albedo_texture == null, "Ожидался материал без текстур")
			var arrays := object.mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			triangles += indices.size() / 3
	_expect(triangles == int(manifest["export_triangles"]), "Количество треугольников не совпадает с экспортом")
	_expect(manifest["footprint_axial"].size() == 9, "Ожидалось основание на девять гексов")
	instance.free()
	for message in _errors:
		push_error(message)
	print("Горный массив: %d меш, %d треугольников, ошибок: %d" % [meshes.size(), triangles, _errors.size()])
	_preview = OS.get_cmdline_user_args().has("--preview") and _errors.is_empty()
	if not _preview:
		quit(0 if _errors.is_empty() else 1)
		return
	root.size = Vector2i(1600, 1100)
	var scene: Node3D = load(BASE + "preview.tscn").instantiate()
	root.add_child(scene)

func _process(_delta: float) -> bool:
	if _preview:
		_frames += 1
		if _frames == 30:
			var error := root.get_texture().get_image().save_png(BASE + "previews/massif_godot.png")
			print("Рендер Godot: ", error_string(error))
			quit(0 if error == OK else 1)
	return false

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_errors.append(message)

func _collect(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect(child, result)
