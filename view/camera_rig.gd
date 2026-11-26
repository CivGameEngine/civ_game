class_name CameraRig
extends Node3D
## Камера стратегии: наклонный вид сверху, прокрутка WASD/стрелками и
## перетаскиванием средней кнопкой, масштаб колесом. По горизонтали
## позиция зациклена по ширине карты.

@export var pitch_deg := 52.0
@export var min_distance := 5.0
@export var max_distance := 42.0
@export var pan_speed := 1.1

var distance := 13.0
var target_distance := 13.0
var world_width := 0.0
var min_z := 0.0
var max_z := 0.0

var camera: Camera3D
var _dragging := false


func _ready() -> void:
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.near = 0.1
	camera.far = 300.0
	add_child(camera)
	_update_camera()


func setup(map_world_width: float, map_world_depth: float) -> void:
	world_width = map_world_width
	min_z = 0.0
	max_z = map_world_depth


func focus(p: Vector3) -> void:
	position = Vector3(p.x, 0, p.z)
	_clamp()


func _process(delta: float) -> void:
	var move := Vector2(
		Input.get_axis("cam_left", "cam_right"),
		Input.get_axis("cam_up", "cam_down"))
	if move != Vector2.ZERO:
		var speed := pan_speed * distance * delta
		position += Vector3(move.x, 0, move.y) * speed
		_clamp()
	if absf(distance - target_distance) > 0.01:
		distance = lerpf(distance, target_distance, minf(1.0, delta * 10.0))
		_update_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			target_distance = maxf(min_distance, target_distance * 0.88)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			target_distance = minf(max_distance, target_distance / 0.88)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var k := distance * 0.0022
		position -= Vector3(mm.relative.x, 0, mm.relative.y) * k
		_clamp()


func _clamp() -> void:
	if world_width > 0.0:
		position.x = fposmod(position.x, world_width)
	position.z = clampf(position.z, min_z, max_z)


func _update_camera() -> void:
	if camera == null:
		return
	var pitch := deg_to_rad(pitch_deg)
	camera.position = Vector3(0, sin(pitch) * distance, cos(pitch) * distance)
	camera.look_at(global_position, Vector3.UP)
