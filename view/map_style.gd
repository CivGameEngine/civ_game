class_name MapStyle
extends RefCounted
## Визуальные параметры карты: общая плоскость и палитра. Временные цвета до
## появления рисованных текстур — их можно смело менять здесь.

## Локальный радиус для геометрии и моделей; мировой радиус задаёт шаг игровой сетки.
const HEX_SIZE := 1.0
const WORLD_HEX_RADIUS := 0.5
const BIOME_ORDER := ["GRASS", "PLAINS", "DESERT", "TUNDRA", "SNOW", "COAST", "LAKE", "OCEAN"]

static func biome_index(map: GameMap, tile: int) -> int:
	return maxi(0, BIOME_ORDER.find(map.terrain[tile]))

# Общий уровень всех тайлов. Горы и холмы изображаются отдельными моделями.
const H_FLAT := 0.0
const WATER_Y := H_FLAT

const TERRAIN_COLORS := {
	"GRASS": Color("86a15a"),
	"PLAINS": Color("b3a669"),
	"DESERT": Color("d8c391"),
	"TUNDRA": Color("979c86"),
	"SNOW": Color("e6eaed"),
	"COAST": Color("b9b48a"),
	"LAKE": Color("8fa88a"),
	"OCEAN": Color("5d7d84"),
}

const FEATURE_TINT := {
	"FLOODPLAINS": Color("98a24a"),
	"MARSH": Color("5f8a6a"),
	"OASIS": Color("8fbf5a"),
	"RAINFOREST": Color("5d8a3e"),
	"WOODS": Color("6f8f46"),
	"GEOTHERMAL": Color("b98a6a"),
	"REEF": Color("62aaa3"),
	"ICE": Color("d7e7ec"),
}

const WALL_LAND := Color("8a6a4c")
const WALL_ROCK := Color("7d746c")
const WALL_SEABED := Color("b5a77a")

const MOUNTAIN_ROCK := Color("8b7f74")
const MOUNTAIN_ROCK_HI := Color("a89f94")
const MOUNTAIN_SNOW := Color("f3f4f6")

# Осенняя палитра леса — как в референсе.
const WOODS_COLORS: Array[Color] = [
	Color("d98a3a"), Color("e3b14e"), Color("c86a36"), Color("a8503a"),
	Color("8a9a48"), Color("caa045"), Color("7f9446"),
]
const CONIFER_COLORS: Array[Color] = [Color("4f6e45"), Color("5d7b4c"), Color("3f5c3c")]
const RAINFOREST_COLORS: Array[Color] = [Color("3f7a3a"), Color("4e8c3f"), Color("2f6634"), Color("6a9a3e")]
const TRUNK_COLOR := Color("6b4a32")

const RIVER_COLOR := Color("5aa8d8")
const WATER_SHALLOW := Color(0.36, 0.66, 0.72, 0.72)
const WATER_DEEP := Color(0.16, 0.33, 0.45, 0.9)

const RESOURCE_COLORS := {
	"bonus": Color("7ccf5a"),
	"luxury": Color("c27ae0"),
	"strategic": Color("e05a4a"),
}

const FOG_UNEXPLORED := Color("1e2229")


static func tile_height(_map: GameMap, _i: int) -> float:
	return H_FLAT


## Детерминированный «шум» по номеру клетки для живописных вариаций цвета.
static func hash01(i: int, salt: int = 0) -> float:
	var h := (i * 73856093) ^ (salt * 19349663) ^ 0x5bd1e995
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 65535.0


static func top_color(map: GameMap, i: int) -> Color:
	var c: Color = TERRAIN_COLORS.get(map.terrain[i], Color.MAGENTA)
	var f := map.feature[i]
	if FEATURE_TINT.has(f):
		c = c.lerp(FEATURE_TINT[f], 0.35)
	var v := (hash01(i) - 0.5) * 0.07
	return Color(clampf(c.r + v, 0, 1), clampf(c.g + v, 0, 1), clampf(c.b + v * 0.6, 0, 1))
