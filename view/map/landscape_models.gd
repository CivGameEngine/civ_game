extends RefCounted
## Исходные импортированные меши общие; материалы с туманом создаёт каждый MapView.
static var _meshes: Dictionary = {}
static var _config: Dictionary = {}

static func config() -> Dictionary:
	if _config.is_empty():
		_config = JSON.parse_string(FileAccess.get_file_as_string("res://data/landscape_visuals.json"))
	return _config

static func mesh(id: String) -> ArrayMesh:
	if not _meshes.has(id):
		var files: Dictionary = config().get("model_files", {})
		var path: String = files.get(id, str(config()["model_dir"]) + id + ".gltf")
		var scene := load(path) as PackedScene
		if scene == null:
			push_error("Не удалось загрузить модель ландшафта: " + id)
			return null
		var root := scene.instantiate()
		var found := _find_mesh(root)
		if found != null:
			_meshes[id] = found
		root.free()
	return _meshes.get(id) as ArrayMesh

static func _find_mesh(node: Node) -> ArrayMesh:
	if node is MeshInstance3D:
		return node.mesh as ArrayMesh
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null
