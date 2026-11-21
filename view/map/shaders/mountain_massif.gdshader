shader_type spatial;
render_mode diffuse_lambert_wrap, specular_disabled, cull_back;
#include "res://view/map/shaders/fog.gdshaderinc"
#include "res://view/map/shaders/landscape_pbr.gdshaderinc"

uniform sampler2D mountain_mask : filter_nearest, repeat_disable;
uniform sampler2D edge_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 map_size;
uniform float hex_size = 1.0;
uniform float edge_fade = 0.38;
uniform vec4 fit_rect;
varying vec2 world_xz;
varying vec2 source_xz;
varying vec3 world_position;
varying vec3 world_normal;
varying flat int group_id;
varying flat float native_shape;
const float SQRT3 = 1.7320508075688772;

// Округление кубических координат совпадает с HexGrid.index_at_world.
vec4 cell_at(vec2 point) {
	vec2 p = point / hex_size;
	vec2 axial = vec2(p.x / SQRT3 - p.y / 3.0, p.y / 1.5);
	vec3 cube = round(vec3(axial, -axial.x - axial.y));
	vec3 delta = abs(cube - vec3(axial, -axial.x - axial.y));
	if (delta.x > delta.y && delta.x > delta.z) { cube.x = -cube.y - cube.z; }
	else if (delta.y > delta.z) { cube.y = -cube.x - cube.z; }
	float col = mod(cube.x + floor(cube.y * 0.5), map_size.x);
	return vec4(col, cube.y, SQRT3 * (cube.x + cube.y * 0.5), 1.5 * cube.y);
}

vec4 mask_at(vec4 cell) {
	if (cell.y < 0.0 || cell.y >= map_size.y) { return vec4(0.0); }
	return textureLod(mountain_mask, (cell.xy + vec2(0.5)) / map_size, 0.0);
}

int mask_group(vec4 mask) { return int(round(mask.r * 255.0)) + 256 * int(round(mask.g * 255.0)); }

// Спуск только на внешних рёбрах группы. Общие рёбра гор не образуют щелей.
vec3 boundary_fade(vec2 point) {
	vec4 cell = cell_at(point);
	vec4 mask = mask_at(cell);
	if (mask_group(mask) != group_id) { return vec3(0.0); }
	int edges = int(round(mask.b * 255.0));
	vec2 local = point / hex_size - cell.zw;
	float distance = edge_fade;
	vec2 direction = vec2(0.0);
	for (int d = 0; d < 6; d++) {
		if ((edges & (1 << d)) == 0) { continue; }
		float angle = -float(d) * 1.0471975512;
		vec2 normal = vec2(cos(angle), sin(angle));
		float edge_distance = SQRT3 * 0.5 - dot(local, normal);
		if (edge_distance < distance) { distance = edge_distance; direction = normal; }
	}
	float t = clamp(distance / edge_fade, 0.0, 1.0);
	float gradient = 6.0 * t * (1.0 - t) / (edge_fade * hex_size);
	return vec3(t * t * (3.0 - 2.0 * t), -direction * gradient);
}

void vertex() {
	group_id = int(round(INSTANCE_CUSTOM.r));
	native_shape = INSTANCE_CUSTOM.g;
	source_xz = VERTEX.xz;
	vec3 position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_xz = position.xz;
	vec3 fade = boundary_fade(world_xz);
	if (native_shape > 0.5) { fade = vec3(1.0, 0.0, 0.0); }
	vec3 normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vec3 adjusted = vec3(fade.x * normal.x - position.y * fade.y * normal.y,
		normal.y, fade.x * normal.z - position.y * fade.z * normal.y);
	if (dot(adjusted, adjusted) < 0.000001) { adjusted = vec3(0.0, 1.0, 0.0); }
	NORMAL = normalize(transpose(mat3(MODEL_MATRIX)) * adjusted);
	VERTEX.y *= fade.x;
	world_normal = normalize(adjusted);
	world_position = vec3(position.x, position.y * fade.x, position.z);
}

void fragment() {
	if (native_shape < 0.5 && (source_xz.x < fit_rect.x || source_xz.y < fit_rect.y || source_xz.x > fit_rect.z || source_xz.y > fit_rect.w)) { discard; }
	vec4 cell = cell_at(world_xz);
	if (mask_group(mask_at(cell)) != group_id) { discard; }
	float fog = fog_lookup((cell.xy + vec2(0.5)) / map_size);
	if (fog < 0.25) { discard; }
	float blend = native_shape > 0.5 ? 1.0 : smoothstep(0.3, 0.95, boundary_fade(world_xz).x);
	vec3 weights = pow(abs(normalize(world_normal)), vec3(3.0));
	weights /= max(0.0001, weights.x + weights.y + weights.z);
	vec3 rock = texture(edge_albedo, world_position.yz * 1.2).rgb * weights.x
		+ texture(edge_albedo, world_position.xz * 1.2).rgb * weights.y
		+ texture(edge_albedo, world_position.xy * 1.2).rgb * weights.z;
	ALBEDO = apply_fog_tint(mix(rock, landscape_albedo(UV), blend), fog);
	ROUGHNESS = landscape_roughness(UV);
	if (has_normal) { NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), texture(normal_texture, UV).rgb, blend); NORMAL_MAP_DEPTH = normal_scale; }
}
