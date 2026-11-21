extends RefCounted
## Связные горные группы для отображения. Карта и ГПСЧ партии не меняются.
## Маска: RG — номер группы (16 бит), B — открытые внешние рёбра (6 бит).

static func build(map: GameMap, cfg: Dictionary, footprint: Array) -> Dictionary:
	var labels := PackedInt32Array()
	labels.resize(map.size())
	var groups: Array[Dictionary] = []
	# Сначала ищем полные отпечатки модели внутри больших цепей, чтобы как
	# можно чаще показывать исходный массив целиком и без деформации.
	for anchor in map.size():
		if labels[anchor] != 0 or not map.is_mountain(anchor) or map.is_water(anchor):
			continue
		for steps in HexGrid.DIR_COUNT:
			var tiles: Array[int] = []
			for cell in footprint:
				var offset := _rotate(Vector2i(int(cell[0]), int(cell[1])), steps)
				var tile := map.grid.index_of_axial(map.grid.axial_of(anchor) + offset)
				if tile < 0 or labels[tile] != 0 or not map.is_mountain(tile) or map.is_water(tile) or tiles.has(tile):
					break
				tiles.append(tile)
			if tiles.size() != footprint.size():
				continue
			var id := groups.size() + 1
			for tile in tiles:
				labels[tile] = id
			var point := map.grid.world_position(anchor, MapStyle.HEX_SIZE)
			groups.append({"id": id, "tiles": tiles, "native": true,
				"transform": Transform3D(Basis(Vector3.UP, -steps * PI / 3.0), Vector3(point.x, 0, point.y))})
			break
	for tile in map.size():
		if labels[tile] != 0 or not map.is_mountain(tile) or map.is_water(tile):
			continue
		var id := groups.size() + 1
		var tiles: Array[int] = [tile]
		var positions := {tile: map.grid.world_position(tile, MapStyle.HEX_SIZE)}
		labels[tile] = id
		var cursor := 0
		while cursor < tiles.size():
			var current := tiles[cursor]
			cursor += 1
			for direction in HexGrid.DIR_COUNT:
				if tiles.size() >= int(cfg["max_tiles"]):
					break
				var neighbor := map.grid.neighbor(current, direction)
				if neighbor < 0 or labels[neighbor] != 0 or not map.is_mountain(neighbor) or map.is_water(neighbor):
					continue
				labels[neighbor] = id
				tiles.append(neighbor)
				var angle := -direction * PI / 3.0
				positions[neighbor] = positions[current] + Vector2(cos(angle), sin(angle)) * HexGrid.SQRT3 * MapStyle.HEX_SIZE
		var placement := _native(map, tiles, positions, footprint)
		if placement.is_empty():
			placement = _fit(tiles, positions, cfg, footprint.size())
		placement["id"] = id
		placement["tiles"] = tiles
		groups.append(placement)
	var image := Image.create(map.width, map.height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	for tile in map.size():
		var id := labels[tile]
		if id == 0:
			continue
		var edges := 0
		for direction in HexGrid.DIR_COUNT:
			var neighbor := map.grid.neighbor(tile, direction)
			if neighbor < 0 or labels[neighbor] != id:
				edges |= 1 << direction
		image.set_pixel(map.grid.col_of(tile), map.grid.row_of(tile), Color((id & 255) / 255.0, (id >> 8) / 255.0, edges / 255.0, 1))
	return {"groups": groups, "labels": labels, "image": image}

static func _rotate(point: Vector2i, steps: int) -> Vector2i:
	for step in steps:
		point = Vector2i(-point.y, point.x + point.y)
	return point

## При совпадении девяти гексов сохраняем модель целиком, в исходном масштабе.
static func _native(map: GameMap, tiles: Array[int], positions: Dictionary, footprint: Array) -> Dictionary:
	if tiles.size() != footprint.size():
		return {}
	for anchor in tiles:
		for steps in HexGrid.DIR_COUNT:
			var matched := true
			var mapped := {}
			for cell in footprint:
				var offset := _rotate(Vector2i(int(cell[0]), int(cell[1])), steps)
				var tile := map.grid.index_of_axial(map.grid.axial_of(anchor) + offset)
				if not tiles.has(tile) or mapped.has(tile):
					matched = false
					break
				mapped[tile] = true
			if matched:
				var point: Vector2 = positions[anchor]
				return {"native": true, "transform": Transform3D(Basis(Vector3.UP, -steps * PI / 3.0), Vector3(point.x, 0, point.y))}
	return {}

## Остальные контуры получают один адаптированный массив, а не гору на клетку.
## Контур ограничит шейдер; внутри группы высота не обрывается по границам тайлов.
static func _fit(tiles: Array[int], positions: Dictionary, cfg: Dictionary, reference_tiles: int) -> Dictionary:
	var rect: Array = cfg["fit_rect"]
	var source_min := Vector2(float(rect[0]), float(rect[1]))
	var source_size := Vector2(float(rect[2]), float(rect[3])) - source_min
	var anchor: Vector2 = positions[tiles[0]]
	var best_score := INF
	var result := Transform3D.IDENTITY
	var start := int(MapStyle.hash01(tiles[0], 303) * HexGrid.DIR_COUNT)
	for variant in HexGrid.DIR_COUNT:
		var steps := (start + variant) % HexGrid.DIR_COUNT
		var rotation := Basis(Vector3.UP, -steps * PI / 3.0)
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		for tile in tiles:
			var point: Vector2 = positions[tile] - anchor
			var local := rotation.inverse() * Vector3(point.x, 0, point.y)
			low = low.min(Vector2(local.x, local.z))
			high = high.max(Vector2(local.x, local.z))
		low -= Vector2(HexGrid.SQRT3 * 0.5, 1) * MapStyle.HEX_SIZE
		high += Vector2(HexGrid.SQRT3 * 0.5, 1) * MapStyle.HEX_SIZE
		var scale := (high - low) / source_size
		var score := absf(log(scale.x / scale.y))
		if score >= best_score - 0.00001:
			continue
		best_score = score
		var height := clampf(sqrt(tiles.size() / float(reference_tiles)), float(cfg["min_height_scale"]), float(cfg["max_height_scale"]))
		var offset := low - source_min * scale
		result = Transform3D(rotation * Basis.from_scale(Vector3(scale.x, height, scale.y)),
			Vector3(anchor.x, 0, anchor.y) + rotation * Vector3(offset.x, 0, offset.y))
	return {"native": false, "transform": result}
