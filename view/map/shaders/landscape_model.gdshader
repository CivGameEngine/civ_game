// UV моделей Blender сохранены. INSTANCE_CUSTOM.xy задаёт клетку тумана войны.
shader_type spatial;
render_mode diffuse_lambert_wrap, specular_disabled, cull_disabled;
#include "res://view/map/shaders/fog.gdshaderinc"
#include "res://view/map/shaders/landscape_pbr.gdshaderinc"
varying flat float fog_state;

void vertex() {
	fog_state = fog_lookup(INSTANCE_CUSTOM.xy);
	if (fog_state < 0.25) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	if (fog_state < 0.25) { discard; }
	ALBEDO = apply_fog_tint(landscape_albedo(UV), fog_state);
	ROUGHNESS = landscape_roughness(UV);
	if (has_normal) { NORMAL_MAP = texture(normal_texture, UV).rgb; NORMAL_MAP_DEPTH = normal_scale; }
}
