shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
#include "res://view/map/shaders/fog.gdshaderinc"
uniform sampler2D flag_sheet : source_color, filter_linear, repeat_disable;
uniform vec4 regions[60];
varying flat float fog_state;
varying vec2 atlas_uv;

void vertex() {
	fog_state = fog_lookup(INSTANCE_CUSTOM.xy);
	int index = int(floor(INSTANCE_CUSTOM.z * 63.0 + 0.5));
	vec4 region = regions[index];
	atlas_uv = region.xy + UV * region.zw;
	VERTEX *= length(MODEL_MATRIX[0].xyz);
	// Флаг всегда обращён к камере, но остаётся привязан к тайлу.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	if (fog_state < 0.25) { discard; }
	vec4 pixel = texture(flag_sheet, atlas_uv);
	ALPHA = pixel.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALBEDO = apply_fog_tint(pixel.rgb, fog_state);
}
