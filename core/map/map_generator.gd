class_name MapGenerator
extends RefCounted
## Генератор карты (ГДД 1, 3). Детерминирован по зерну ГПСЧ партии.
##
## Этапы: высоты → вода/суша → рельеф (горы, холмы) → климат и ландшафт →
## побережье и озёра → реки по рёбрам → особенности → континенты → ресурсы →
## стартовые позиции.

var data: GameData
var rng: GameRng
var map: GameMap
var grid: HexGrid

var map_type: Dictionary
var num_civs: int

# Промежуточные поля (не сохраняются).
var elevation: PackedFloat32Array
var temperature: PackedFloat32Array
var moisture: PackedFloat32Array
var sea_level: float

var start_positions := PackedInt32Array()


func _init(game_data: GameData, game_rng: GameRng) -> void:
	data = game_data
	rng = game_rng


## Создаёт карту. settings: {"map_size": id, "map_type": id, "num_civs": n}.
func generate(settings: Dictionary) -> GameMap:
	var size_def := data.map_size(settings.get("map_size", "STANDARD"))
	map_type = data.map_type(settings.get("map_type", "CONTINENTS"))
	num_civs = int(settings.get("num_civs", size_def.get("civs", 8)))
	map = GameMap.new(int(size_def["width"]), int(size_def["height"]), data)
	grid = map.grid
	_make_elevation()
	_make_land_and_relief()
	_make_climate()
	_assign_terrain()
	_make_water_bodies()
	_make_rivers()
	_place_features()
	_assign_continents()
	_place_resources()
	_choose_start_positions()
	return map


# --- Шум на цилиндре -----------------------------------------------------------

func _new_noise(freq: float, octaves: int, kind := FastNoiseLite.FRACTAL_FBM) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = rng.derive_seed() & 0x7fffffff
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_type = kind
	n.fractal_octaves = octaves
	return n


## Значение шума в клетке, бесшовное по горизонтали (выборка на цилиндре).
## Результат примерно в [0, 1].
func _cyl_noise(noise: FastNoiseLite, i: int) -> float:
	var p := grid.world_position(i)
	var circumference := grid.world_width()
	var radius := circumference / TAU
	var angle := p.x / circumference * TAU
	var v := noise.get_noise_3d(cos(angle) * radius, p.y, sin(angle) * radius)
	return clampf(v * 0.5 + 0.5, 0.0, 1.0)


## Горизонтальное «циклическое» расстояние в долях ширины карты (0..0.5).
func _wrap_dx(x_frac_a: float, x_frac_b: float) -> float:
	var d := absf(x_frac_a - x_frac_b)
	return minf(d, 1.0 - d)


# --- Этап 1: высоты ------------------------------------------------------------

func _make_elevation() -> void:
	var n := map.size()
	elevation.resize(n)
	var blobs: int = int(map_type.get("blobs", 2))
	var base_freq := 0.06 if blobs != 0 else 0.12
	var noise := _new_noise(base_freq, 5)
	var detail := _new_noise(0.25, 3)
	# Центры масс суши (в долях ширины/высоты).
	var centers: Array[Vector2] = []
	if blobs > 0:
		var offset := rng.randf()
		for b in blobs:
			var x := fposmod(offset + float(b) / blobs + rng.randf_range(-0.08, 0.08), 1.0)
			var y := rng.randf_range(0.38, 0.62)
			centers.append(Vector2(x, y))
	for i in n:
		var col := grid.col_of(i)
		var row := grid.row_of(i)
		var xf := (col + 0.5 * (row & 1)) / float(grid.width)
		var yf := row / float(grid.height - 1)
		var e := _cyl_noise(noise, i) * 0.75 + _cyl_noise(detail, i) * 0.25
		if blobs > 0:
			var mask := 0.0
			for c in centers:
				var dx := _wrap_dx(xf, c.x) * float(grid.width) / float(grid.height)
				var dy := yf - c.y
				# Эллипс, вытянутый по горизонтали.
				var dist := sqrt(dx * dx / (0.55 * 0.55 / blobs) + dy * dy / 0.16)
				mask = maxf(mask, 1.0 - dist)
			e = e * 0.55 + clampf(mask, 0.0, 1.0) * 0.6
		elif blobs == -2:
			# Внутреннее море: вода в центре карты.
			var dx2 := _wrap_dx(xf, 0.5) * 2.0
			var dy2 := (yf - 0.5) * 2.0
			var center_dist := sqrt(dx2 * dx2 * 0.6 + dy2 * dy2)
			e = e * 0.6 + clampf(center_dist, 0.0, 1.0) * 0.5
		# Полярные области уходят под воду.
		var polar := absf(yf - 0.5) * 2.0
		if polar > 0.8:
			e -= (polar - 0.8) * 1.5
		elevation[i] = e


# --- Этап 2: суша, горы, холмы -------------------------------------------------

func _make_land_and_relief() -> void:
	var n := map.size()
	var sorted := Array(elevation)
	sorted.sort()
	var land_fraction: float = map_type.get("land_fraction", 0.38)
	sea_level = sorted[clampi(int(n * (1.0 - land_fraction)), 0, n - 1)]
	var ridge := _new_noise(0.09, 4, FastNoiseLite.FRACTAL_RIDGED)
	var hill_noise := _new_noise(0.2, 2)
	var land: Array[int] = []
	for i in n:
		if elevation[i] >= sea_level:
			map.terrain[i] = "GRASS"   # уточнится климатом
			land.append(i)
		else:
			map.terrain[i] = "OCEAN"
	# Горы: хребты, где высокий ridged-шум совпадает с возвышенностью.
	var mountain_score := {}
	for i in land:
		mountain_score[i] = _cyl_noise(ridge, i) * 0.7 + (elevation[i] - sea_level) * 0.6
	var by_score := land.duplicate()
	by_score.sort_custom(func(a, b): return mountain_score[a] > mountain_score[b])
	_place_mountain_massifs(by_score, land.size())
	# Холмы: около гор и по отдельному шуму.
	for i in land:
		if map.relief[i] != GameMap.RELIEF_FLAT:
			continue
		var near_mountain := false
		for nb in grid.neighbors(i):
			if map.relief[nb] == GameMap.RELIEF_MOUNTAIN:
				near_mountain = true
				break
		var p := _cyl_noise(hill_noise, i)
		if (near_mountain and rng.chance(0.45)) or p > 0.66:
			map.relief[i] = GameMap.RELIEF_HILLS


## Цельные горные участки вместо россыпи отдельных непроходимых клеток.
## Контур — игровые данные, без зависимостей ядра от моделей или отображения.
func _place_mountain_massifs(candidates: Array, land_count: int) -> void:
	var cfg: Dictionary = data.setup["mountain_generation"]
	var footprint: Array = cfg["footprint_axial"]
	var target := roundi(land_count * float(cfg["land_fraction"]) / footprint.size())
	var placed := 0
	for anchor in candidates:
		if placed >= target:
			break
		for variant in HexGrid.DIR_COUNT:
			var steps := (int(anchor) + variant) % HexGrid.DIR_COUNT
			var tiles: Array[int] = []
			for cell in footprint:
				var offset := Vector2i(int(cell[0]), int(cell[1]))
				for step in steps:
					offset = Vector2i(-offset.y, offset.x + offset.y)
				var tile := grid.index_of_axial(grid.axial_of(int(anchor)) + offset)
				if tile < 0 or map.is_water(tile) or map.is_mountain(tile) or tiles.has(tile):
					break
				var adjacent := false
				for neighbor in grid.neighbors(tile):
					if map.is_mountain(neighbor):
						adjacent = true
						break
				if adjacent:
					break
				tiles.append(tile)
			if tiles.size() != footprint.size():
				continue
			for tile in tiles:
				map.relief[tile] = GameMap.RELIEF_MOUNTAIN
			placed += 1
			break


# --- Этап 3: климат и ландшафт ------------------------------------------------------

func _make_climate() -> void:
	var n := map.size()
	temperature.resize(n)
	moisture.resize(n)
	var t_noise := _new_noise(0.08, 3)
	var m_noise := _new_noise(0.07, 4)
	for i in n:
		var yf := grid.row_of(i) / float(grid.height - 1)
		var lat := absf(yf - 0.5) * 2.0          # 0 экватор, 1 полюс
		var t := 1.0 - lat * 1.05 + (_cyl_noise(t_noise, i) - 0.5) * 0.3
		if map.relief[i] == GameMap.RELIEF_HILLS:
			t -= 0.04
		temperature[i] = t
		moisture[i] = _cyl_noise(m_noise, i)


func _assign_terrain() -> void:
	for i in map.size():
		if map.terrain[i] == "OCEAN":
			continue
		var t := temperature[i]
		var m := moisture[i]
		if t < 0.12:
			map.terrain[i] = "SNOW"
		elif t < 0.27:
			map.terrain[i] = "TUNDRA"
		elif t > 0.6 and m < 0.36:
			map.terrain[i] = "DESERT"
		elif m > 0.5:
			map.terrain[i] = "GRASS"
		else:
			map.terrain[i] = "PLAINS"


# --- Этап 4: побережье и озёра ---------------------------------------------------------

func _make_water_bodies() -> void:
	var n := map.size()
	# Мелководье: вода рядом с сушей, а также частично на расстоянии 2.
	var near_land := PackedByteArray()
	near_land.resize(n)
	for i in n:
		if map.is_water(i):
			continue
		for nb in grid.neighbors(i):
			near_land[nb] = 1
	for i in n:
		if map.terrain[i] != "OCEAN":
			continue
		if near_land[i] == 1:
			map.terrain[i] = "COAST"
	for i in n:
		if map.terrain[i] != "OCEAN":
			continue
		for nb in grid.neighbors(i):
			if near_land[nb] == 1 and elevation[i] > sea_level - 0.05 and rng.chance(0.5):
				map.terrain[i] = "COAST"
				break
	# Маленькие замкнутые водоёмы становятся озёрами.
	var visited := PackedByteArray()
	visited.resize(n)
	for i in n:
		if visited[i] == 1 or not map.is_water(i):
			continue
		var body := _flood(i, visited, func(x): return map.is_water(x))
		if body.size() <= 8:
			for x in body:
				map.terrain[x] = "LAKE"


## Заливка связной области, удовлетворяющей предикату. Отмечает visited.
func _flood(start: int, visited: PackedByteArray, pred: Callable) -> PackedInt32Array:
	var result := PackedInt32Array()
	var stack := [start]
	visited[start] = 1
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		result.append(cur)
		for nb in grid.neighbors(cur):
			if visited[nb] == 0 and pred.call(nb):
				visited[nb] = 1
				stack.append(nb)
	return result


# --- Этап 5: реки по рёбрам ------------------------------------------------------------
#
# Ребро задаётся (клетка t, направление d); его концы — вершины d и d+1 клетки t.
# Состояние прохода: (t, d, plus): «голова» реки в вершине d+1 (plus) или d (minus).
# Из головы выходят ещё два ребра (третье — то, по которому пришли):
#   plus:  (t, d+1, plus)   и (A = сосед(t,d), d+2, minus)
#   minus: (t, d-1, minus)  и (A = сосед(t,d), d+4, plus)

func _vertex_tiles(t: int, d: int, plus: bool) -> Array[int]:
	var a := grid.neighbor(t, d)
	var b := grid.neighbor(t, (d + 1) % 6) if plus else grid.neighbor(t, (d + 5) % 6)
	return [t, a, b]


func _vertex_key(tiles: Array[int]) -> String:
	var s := tiles.duplicate()
	s.sort()
	return "%d,%d,%d" % [s[0], s[1], s[2]]


func _edge_height(t: int, d: int) -> float:
	var nb := grid.neighbor(t, d)
	if nb < 0:
		return 99.0
	return (elevation[t] + elevation[nb]) * 0.5


func _make_rivers() -> void:
	var land_count := 0
	for i in map.size():
		if map.is_land(i):
			land_count += 1
	var target := maxi(2, land_count / 45)
	var candidates: Array[int] = []
	for i in map.size():
		if map.is_land(i) and not map.is_mountain(i) and not map.is_coastal_land(i) \
				and map.terrain[i] != "SNOW":
			var high := map.is_hills(i)
			for nb in grid.neighbors(i):
				if map.is_mountain(nb):
					high = true
			if high:
				candidates.append(i)
	rng.shuffle(candidates)
	var made := 0
	for src in candidates:
		if made >= target:
			break
		var too_close := false
		for x in grid.tiles_in_radius(src, 2):
			if map.has_river(x):
				too_close = true
				break
		if too_close:
			continue
		if _try_river(src):
			made += 1


func _try_river(src: int) -> bool:
	# Начальное ребро — в сторону самого низкого соседа-суши.
	var best_d := -1
	var best_h := INF
	for d in 6:
		var nb := grid.neighbor(src, d)
		if nb >= 0 and map.is_land(nb) and not map.is_mountain(nb):
			var h := _edge_height(src, d) + rng.randf() * 0.01
			if h < best_h:
				best_h = h
				best_d = d
	if best_d < 0:
		return false
	var path: Array = [[src, best_d]]
	var t := src
	var d := best_d
	var plus := rng.chance(0.5)
	var visited := {}
	visited[_vertex_key(_vertex_tiles(t, d, not plus))] = true
	for _step in 40:
		var vt := _vertex_tiles(t, d, plus)
		if vt[1] < 0 or vt[2] < 0:
			return false   # упёрлись в край карты
		var key := _vertex_key(vt)
		if visited.has(key):
			return false   # петля
		visited[key] = true
		for x in vt:
			if map.is_water(x):
				return _commit_river(path)
		var a := grid.neighbor(t, d)
		var opts: Array = []
		if plus:
			opts = [[t, (d + 1) % 6, true], [a, (d + 2) % 6, false]]
		else:
			opts = [[t, (d + 5) % 6, false], [a, (d + 4) % 6, true]]
		var chosen = null
		var chosen_h := INF
		for o in opts:
			var ot: int = o[0]
			var od: int = o[1]
			var on := grid.neighbor(ot, od)
			if on < 0 or map.has_river_edge(ot, od):
				continue
			# Река не течёт между двумя горами.
			if map.is_mountain(ot) and map.is_mountain(on):
				continue
			var h := _edge_height(ot, od) + rng.randf() * 0.02
			if h < chosen_h:
				chosen_h = h
				chosen = o
		if chosen == null:
			return false
		t = chosen[0]
		d = chosen[1]
		plus = chosen[2]
		path.append([t, d])
	return false


func _commit_river(path: Array) -> bool:
	if path.size() < 3:
		return false
	for e in path:
		map.set_river_edge(e[0], e[1])
	return true


# --- Этап 6: особенности ------------------------------------------------------------------

func _place_features() -> void:
	var n := map.size()
	for i in n:
		var terr := map.terrain[i]
		var t := temperature[i]
		var m := moisture[i]
		var yf := grid.row_of(i) / float(grid.height - 1)
		var lat := absf(yf - 0.5) * 2.0
		if map.is_water(i):
			if (terr == "OCEAN" or terr == "COAST") and lat > 0.86 + rng.randf() * 0.08:
				map.feature[i] = "ICE"
			elif terr == "COAST" and lat < 0.6 and rng.chance(0.06):
				map.feature[i] = "REEF"
			continue
		if map.is_mountain(i):
			continue
		var flat := map.relief[i] == GameMap.RELIEF_FLAT
		if flat and map.has_river(i) and (terr == "DESERT" or (terr != "SNOW" and terr != "TUNDRA" and rng.chance(0.25))):
			map.feature[i] = "FLOODPLAINS"
		elif terr == "DESERT" and flat and not map.has_river(i) and rng.chance(0.035):
			map.feature[i] = "OASIS"
		elif (terr == "GRASS" or terr == "PLAINS") and t > 0.68 and m > 0.55 and rng.chance(0.7):
			map.feature[i] = "RAINFOREST"
		elif terr == "GRASS" and flat and m > 0.72 and rng.chance(0.35):
			map.feature[i] = "MARSH"
		elif (terr == "GRASS" or terr == "PLAINS" or terr == "TUNDRA") and m > 0.42 and rng.chance(0.55):
			map.feature[i] = "WOODS"
		elif terr != "DESERT" and rng.chance(0.004):
			map.feature[i] = "GEOTHERMAL"


# --- Этап 7: континенты ------------------------------------------------------------------

func _assign_continents() -> void:
	var visited := PackedByteArray()
	visited.resize(map.size())
	var next_id := 0
	for i in map.size():
		if visited[i] == 1 or map.is_water(i):
			continue
		var body := _flood(i, visited, func(x): return map.is_land(x))
		for x in body:
			map.continent[x] = next_id
		next_id += 1


# --- Этап 8: ресурсы -------------------------------------------------------------------------

## Подходит ли клетка для ресурса по правилам placements (data/resources.json).
func can_place_resource(rid: String, i: int) -> bool:
	if map.resource[i] != "" or map.is_mountain(i):
		return false
	if map.feature[i] == "ICE" or map.feature[i] == "OASIS" or map.feature[i] == "GEOTHERMAL":
		return false
	var def: Dictionary = data.resources[rid]
	for p in def.get("placements", []):
		if p.has("terrain") and not p["terrain"].has(map.terrain[i]):
			continue
		if p.has("feature"):
			if not p["feature"].has(map.feature[i]):
				continue
		elif map.feature[i] != "":
			continue
		var rel: String = p.get("relief", "FLAT")
		if rel == "FLAT" and map.relief[i] != GameMap.RELIEF_FLAT:
			continue
		if rel == "HILLS" and map.relief[i] != GameMap.RELIEF_HILLS:
			continue
		return true
	return false


func _place_resources() -> void:
	var land: Array[int] = []
	var coast: Array[int] = []
	for i in map.size():
		if map.is_land(i) and not map.is_mountain(i):
			land.append(i)
		elif map.terrain[i] == "COAST" or map.terrain[i] == "LAKE":
			coast.append(i)
	var by_class := {"bonus": [], "luxury": [], "strategic": []}
	for rid in data.resource_ids:
		by_class[data.resources[rid]["class"]].append(rid)
	var all_tiles: Array = []
	all_tiles.append_array(land)
	all_tiles.append_array(coast)
	_scatter(by_class["bonus"], all_tiles, int(land.size() * 0.09 + coast.size() * 0.07))
	_scatter(by_class["strategic"], all_tiles, int(land.size() * 0.035))
	# Люкс: ограниченный набор видов, гнёздами по 2–4.
	var lux: Array = by_class["luxury"].duplicate()
	rng.shuffle(lux)
	var kinds := mini(lux.size(), num_civs * 2 + 4)
	var clusters := maxi(kinds, int(land.size() * 0.012))
	for c in clusters:
		var rid: String = lux[c % kinds]
		var eligible: Array = []
		for i in all_tiles:
			if can_place_resource(rid, i):
				eligible.append(i)
		if eligible.is_empty():
			continue
		var seed_tile: int = rng.pick(eligible)
		map.resource[seed_tile] = rid
		var extra := rng.randi_range(1, 3)
		for nb in grid.tiles_in_radius(seed_tile, 2):
			if extra <= 0:
				break
			if can_place_resource(rid, nb) and rng.chance(0.5):
				map.resource[nb] = rid
				extra -= 1


func _scatter(ids: Array, tiles: Array, count: int) -> void:
	if ids.is_empty():
		return
	var weights := []
	for rid in ids:
		weights.append(float(data.resources[rid].get("weight", 1)))
	var shuffled := tiles.duplicate()
	rng.shuffle(shuffled)
	var placed := 0
	for i in shuffled:
		if placed >= count:
			break
		if map.resource[i] != "":
			continue
		# Без соседей-ресурсов, чтобы распределение было ровнее.
		var crowded := false
		for nb in grid.neighbors(i):
			if map.resource[nb] != "":
				crowded = true
				break
		if crowded:
			continue
		var options := []
		var opt_w := []
		for k in ids.size():
			if can_place_resource(ids[k], i):
				options.append(ids[k])
				opt_w.append(weights[k])
		var pick := rng.pick_weighted(opt_w)
		if pick >= 0:
			map.resource[i] = options[pick]
			placed += 1


# --- Этап 9: стартовые позиции (ГДД 1) -----------------------------------------------------

## Оценка клетки как стартовой; -1 — клетка не годится.
func start_score(i: int) -> float:
	if map.is_water(i) or map.is_mountain(i):
		return -1.0
	var terr := map.terrain[i]
	if terr == "SNOW" or terr == "DESERT" or terr == "TUNDRA":
		return -1.0
	if map.feature[i] == "MARSH" or map.feature[i] == "FLOODPLAINS" or map.feature[i] == "OASIS":
		return -1.0
	var fresh := map.has_fresh_water(i)
	var coastal := map.is_coastal_land(i)
	if not fresh and not coastal:
		return -1.0
	var food_tiles := 0
	var prod_tiles := 0
	var land_tiles := 0
	var score := 0.0
	for x in grid.tiles_in_radius(i, 2):
		if x == i:
			continue
		var y := Yields.tile_yields(map, data, x, null, false)
		if y.get("food", 0) >= 2:
			food_tiles += 1
		if y.get("production", 0) >= 1:
			prod_tiles += 1
		if map.is_land(x):
			land_tiles += 1
		var w := 1.0 if grid.distance(i, x) == 1 else 0.7
		score += (y.get("food", 0) * 1.0 + y.get("production", 0) * 1.0 + y.get("gold", 0) * 0.5) * w
	if food_tiles < 2 or prod_tiles < 2 or land_tiles < 8:
		return -1.0
	for x in grid.tiles_in_radius(i, 3):
		if grid.distance(i, x) == 3:
			var y3 := Yields.tile_yields(map, data, x, null, false)
			score += (y3.get("food", 0) + y3.get("production", 0)) * 0.4
	score += 12.0 if fresh else 6.0
	if map.is_hills(i):
		score += 2.0
	return score


func _choose_start_positions() -> void:
	var scored: Array = []
	for i in map.size():
		var s := start_score(i)
		if s > 0.0:
			scored.append([s + rng.randf() * 2.0, i])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var min_dist: int = int(data.const_value("start_min_capital_distance", 9))
	while min_dist >= 4:
		start_positions = PackedInt32Array()
		for entry in scored:
			var tile: int = entry[1]
			var ok := true
			for s in start_positions:
				if grid.distance(s, tile) < min_dist:
					ok = false
					break
			if ok:
				start_positions.append(tile)
				if start_positions.size() >= num_civs:
					return
		min_dist -= 1
	push_warning("Не удалось расставить все стартовые позиции: %d из %d" % [start_positions.size(), num_civs])
