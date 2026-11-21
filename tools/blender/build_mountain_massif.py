"""Единый многоклеточный горный массив без текстур, Blender 4.5.

Запуск: blender --background --factory-startup --python tools/blender/build_mountain_massif.py
Существующие модели и игровую сцену скрипт не изменяет.
"""
import bpy
import bmesh
import json
import math
from pathlib import Path
from mathutils import Vector, noise

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'art/landscape/massifs'
for folder in ('source', 'models', 'previews'):
    (OUT / folder).mkdir(parents=True, exist_ok=True)
(OUT / 'source/.gdignore').touch()

# Гексы pointy-top радиуса 1. Непрерывное основание — объединение девяти клеток.
CELLS = [(-1, 0), (0, 0), (1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, -1), (1, -1)]

def key(p):
    return tuple(round(v, 6) for v in p)

def hexagon(q, r):
    cx, cy = math.sqrt(3) * (q + r / 2), 1.5 * r
    return [(cx + math.cos(math.pi / 6 + i * math.pi / 3),
             cy + math.sin(math.pi / 6 + i * math.pi / 3)) for i in range(6)]

edges = {}
for q, r in CELLS:
    points = hexagon(q, r)
    for a, b in zip(points, points[1:] + points[:1]):
        edge_key = tuple(sorted((key(a), key(b))))
        if edge_key in edges:
            del edges[edge_key]
        else:
            edges[edge_key] = (a, b)

def boundary_distance(x, y):
    result = float('inf')
    for a, b in edges.values():
        dx, dy = b[0] - a[0], b[1] - a[1]
        t = max(0, min(1, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy)))
        result = min(result, math.hypot(x - a[0] - dx * t, y - a[1] - dy * t))
    return result

def n(x, y, scale=1.0, seed=0.0):
    return noise.noise(Vector((x * scale + seed, y * scale - seed * .43, 7.31)))

def smooth(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3 - 2 * value)

def profile(distance):
    # Узкий гребень, скальная стенка, затем осыпь; не округлый конус.
    stops = [(0, 1), (.12, .95), (.30, .86), (.48, .77), (.68, .32), (1.0, .11), (1.6, 0)]
    for (a, za), (b, zb) in zip(stops, stops[1:]):
        if distance <= b:
            t = smooth((distance - a) / (b - a))
            return za + (zb - za) * t
    return 0.0

RIDGE = [(-1.85, .1, .45), (-1.35, .48, 2.45), (-.95, .64, 2.94),
         (-.48, .67, 3.13), (-.10, .38, 2.62), (.48, .21, 1.88),
         (1.17, .40, 1.57), (1.65, .17, 1.91), (2.20, -.05, 1.26), (3.18, -.23, .15)]
SPURS = [([(-1.05, .34, 1.63), (-1.24, -.57, 1.02), (-1.8, -1.3, .13)], .62),
         ([(-.20, .23, 1.69), (.02, -.64, 1.12), (.83, -1.42, .28)], .56),
         ([(1.6, .10, 1.25), (1.83, -.75, .78), (2.62, -1.44, .12)], .53),
         ([(-.8, .65, 1.4), (-.9, 1.4, .83), (-.45, 2.05, .10)], .65)]

def ridge_height(x, y, nodes, width):
    result = 0.0
    for a, b in zip(nodes, nodes[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        t = max(0.0, min(1.0, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy)))
        px, py = a[0] + dx * t, a[1] + dy * t
        elevation = a[2] + (b[2] - a[2]) * t
        d = math.hypot(x - px, y - py)
        # Подветренная сторона шире; фасад главного пика обрывистее.
        side = .86 if y < py else 1.15
        rough_d = max(0.0, d + n(x, y, 3.2, 16) * .07)
        result = max(result, elevation * profile(rough_d / (width * side)))
    return result

def elevation(x, y):
    wx = x + n(x, y, 1.3, 23) * .065
    wy = y + n(x, y, 1.3, 38) * .065
    main = ridge_height(wx, wy, RIDGE, 1.04)
    branch = max(ridge_height(wx, wy, nodes, width) for nodes, width in SPURS)
    # Общее подножие соединяет гребни; отдельные валуны не создаются.
    apron = .17 + .25 * math.exp(-((x - .4) / 2.5) ** 2 - (y / 1.35) ** 2)
    height = max(main, branch) + apron
    # Продольные борозды сходят с гребня вниз; вся детализация — геометрия.
    azimuth = math.atan2((y - .60) * .88, x + .55)
    drain = max(0, .58 + n(math.cos(azimuth), math.sin(azimuth), 19, 5)) ** 4
    drain += .5 * max(0, .52 + n(math.cos(azimuth), math.sin(azimuth), 39, 8)) ** 4
    vertical = max(0, .6 + n(x, y * .12, 23, 12)) ** 4
    height -= drain * .18 * min(1.0, height)
    height -= vertical * .08 * min(1.0, height)
    height += n(x, y, 4.0, 47) * .06 + n(x, y, 11.5, 60) * .025
    # Плавный выход к плоскости карты, без стенок между соседними клетками.
    return max(0.0, height) * smooth(boundary_distance(x, y) / .48) * .82

scene = bpy.data.scenes.new('Mountain_Massif_9_Hex_Clay')
bpy.context.window.scene = scene
scene.unit_settings.system = 'METRIC'
assets = bpy.data.collections.new('Massif_Export')
studio = bpy.data.collections.new('Preview_Only')
scene.collection.children.link(assets)
scene.collection.children.link(studio)

vertices, vertex_index = [], {}
faces = []
steps = 44

def vertex_at(x, y):
    coordinate = key((x, y))
    if coordinate not in vertex_index:
        vertex_index[coordinate] = len(vertices)
        vertices.append((x, y, elevation(x, y)))
    return vertex_index[coordinate]

# Равномерные равносторонние треугольники вместо веера длинных узких граней.
# Совпадающие вершины соседних гексов свариваются, внутренних стенок нет.
for q, r in CELLS:
    center = (math.sqrt(3) * (q + r / 2), 1.5 * r)
    corners = hexagon(q, r)
    for a, b in zip(corners, corners[1:] + corners[:1]):
        indices = {}
        for i in range(steps + 1):
            for j in range(steps + 1 - i):
                x = center[0] + (a[0] - center[0]) * i / steps + (b[0] - center[0]) * j / steps
                y = center[1] + (a[1] - center[1]) * i / steps + (b[1] - center[1]) * j / steps
                indices[i, j] = vertex_at(x, y)
        for i in range(steps):
            for j in range(steps - i):
                faces.append((indices[i, j], indices[i + 1, j], indices[i, j + 1]))
                if i + j < steps - 1:
                    faces.append((indices[i + 1, j], indices[i + 1, j + 1], indices[i, j + 1]))
# Дно повторяет триангуляцию девяти гексов: не перекрывает вогнутые участки контура.
bottom_map = {}
for index, (x, y, z) in enumerate(vertices[:]):
    if z < 1e-8:
        bottom_map[index] = index
    else:
        bottom_map[index] = len(vertices)
        vertices.append((x, y, 0.0))
faces += [tuple(bottom_map[index] for index in reversed(face)) for face in faces[:]]

mesh = bpy.data.meshes.new('Massif_Continuous_Closed_Surface')
mesh.from_pydata(vertices, [], faces)
mesh.validate(clean_customdata=True)
bm = bmesh.new()
bm.from_mesh(mesh)
bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
assert all(edge.is_manifold for edge in bm.edges)
bm.to_mesh(mesh)
bm.free()
mesh.update()
model = bpy.data.objects.new('mountain_massif_9hex_v1', mesh)
assets.objects.link(model)

clay = bpy.data.materials.new('Neutral_Gray_No_Textures')
clay.diffuse_color = (.26, .275, .29, 1)
clay.use_nodes = True
bsdf = next(node for node in clay.node_tree.nodes if node.type == 'BSDF_PRINCIPLED')
bsdf.inputs['Base Color'].default_value = clay.diffuse_color
bsdf.inputs['Roughness'].default_value = .9
model.data.materials.append(clay)
for poly in mesh.polygons:
    poly.use_smooth = True
model['footprint_blender_xy_json'] = json.dumps(CELLS)
model['footprint_godot_axial_json'] = json.dumps([(q + r, -r) for q, r in CELLS])
model['hex_radius'] = 1.0
model['notes'] = 'Одна замкнутая поверхность; 9 гексов; без текстур. Не подключена к карте.'

# Служебная сетка вынесена в отдельную коллекцию и не экспортируется.
line_material = bpy.data.materials.new('Preview_Grid_Only')
line_material.diffuse_color = (.07, .27, .30, 1)
for q, r in CELLS:
    curve = bpy.data.curves.new(f'Footprint_{q}_{r}', 'CURVE')
    curve.dimensions = '3D'
    curve.bevel_depth = .012
    spline = curve.splines.new('POLY')
    corners = hexagon(q, r)
    samples = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        for step in range(32):
            t = step / 32
            x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            samples.append((x, y, elevation(x, y) + .024, 1))
    spline.points.add(len(samples) - 1)
    for point, sample in zip(spline.points, samples):
        point.co = sample
    spline.use_cyclic_u = True
    obj = bpy.data.objects.new(curve.name, curve)
    studio.objects.link(obj)
    curve.materials.append(line_material)

world = bpy.data.worlds.new('Massif_Studio')
world.use_nodes = True
bg = next(node for node in world.node_tree.nodes if node.type == 'BACKGROUND')
bg.inputs[0].default_value = (.15, .17, .20, 1)
bg.inputs[1].default_value = .3
scene.world = world
for name, location, energy, size in [('Key', (-4, -5, 9), 650, 4),
                                     ('Fill', (5, -1, 6), 110, 5),
                                     ('Rim', (1, 5, 7), 500, 3)]:
    data = bpy.data.lights.new(name, 'AREA')
    data.energy, data.shape, data.size = energy, 'DISK', size
    obj = bpy.data.objects.new(name, data)
    studio.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (Vector((.5, 0, .8)) - obj.location).to_track_quat('-Z', 'Y').to_euler()
camera_data = bpy.data.cameras.new('Massif_Preview_Camera')
camera = bpy.data.objects.new(camera_data.name, camera_data)
studio.objects.link(camera)
scene.camera = camera
camera_data.type = 'ORTHO'
camera_data.ortho_scale = 8.6
scene.render.engine = 'CYCLES'
scene.cycles.samples = 32
scene.cycles.use_denoising = True
scene.render.resolution_x = 1600
scene.render.resolution_y = 1100
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.view_settings.view_transform = 'AgX'

def aim(location, target=(.6, 0, 1.05)):
    camera.location = location
    camera.rotation_euler = (Vector(target) - camera.location).to_track_quat('-Z', 'Y').to_euler()

def render(name, location, grid=False, target=(.6, 0, 1.05)):
    for obj in studio.objects:
        if obj.type == 'CURVE':
            obj.hide_render = not grid
    aim(location, target)
    scene.render.filepath = str(OUT / 'previews' / name)
    bpy.ops.render.render(write_still=True)

render('massif_front.png', (3.2, -10, 5.5))
render('massif_reverse.png', (-6, 8, 6))
render('massif_footprint.png', (.6, 0, 14), True, (.6, 0, 0))
aim((3.2, -10, 5.5))
for obj in studio.objects:
    if obj.type == 'CURVE':
        obj.hide_render = True
        obj.hide_viewport = True

bpy.ops.object.select_all(action='DESELECT')
model.select_set(True)
bpy.context.view_layer.objects.active = model
source_triangles = len(mesh.polygons)
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == 'VIEW_3D':
            space = area.spaces.active
            space.region_3d.view_location = Vector((.6, 0, 1))
            space.region_3d.view_distance = 10
            space.region_3d.view_rotation = camera.rotation_euler.to_quaternion()
            space.shading.color_type = 'MATERIAL'
            space.clip_end = 100
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'source/mountain_massif_9hex_v1.blend'))

# Игровой экспорт облегчается отдельно, исходная скульптура остаётся нетронутой.
game = model.copy()
game.data = model.data.copy()
assets.objects.link(game)
game.name = 'mountain_massif_9hex_game'
model.select_set(False)
game.select_set(True)
bpy.context.view_layer.objects.active = game
decimate = game.modifiers.new('Export_Simplification', 'DECIMATE')
decimate.ratio = min(1.0, 45000 / source_triangles)
bpy.ops.object.modifier_apply(modifier=decimate.name)
game.data.validate(clean_customdata=True)
game.data.update()
bpy.ops.export_scene.gltf(filepath=str(OUT / 'models/mountain_massif_9hex_v1.glb'),
                          use_selection=True, use_active_scene=True, export_animations=False,
                          export_cameras=False, export_lights=False)

bm = bmesh.new()
bm.from_mesh(game.data)
bm.verts.ensure_lookup_table()
visited, stack = set(), [bm.verts[0]]
while stack:
    vertex = stack.pop()
    if vertex in visited:
        continue
    visited.add(vertex)
    stack.extend(edge.other_vert(vertex) for edge in vertex.link_edges)
assert len(visited) == len(bm.verts), 'Disconnected mesh'
assert all(edge.is_manifold for edge in bm.edges), 'Nonmanifold export'
assert not any(node.type == 'TEX_IMAGE' for node in clay.node_tree.nodes)
game_triangles = sum(len(poly.vertices) - 2 for poly in game.data.polygons)
bm.free()
model.hide_render = True
render('massif_game_mesh.png', (3.2, -10, 5.5))
manifest = {'id': 'mountain_massif_9hex_v1', 'prototype': True,
            'source': 'source/mountain_massif_9hex_v1.blend',
            'model': 'models/mountain_massif_9hex_v1.glb', 'hex_radius': 1.0,
            'footprint_axial': [(q + r, -r) for q, r in CELLS],
            'footprint_blender_xy': CELLS, 'source_triangles': source_triangles,
            'export_triangles': game_triangles, 'textures': [],
            'connected_components': 1, 'closed_manifold': True,
            'bounds_export_blender_z_up': {'min': [min(v.co[i] for v in game.data.vertices) for i in range(3)],
                                           'max': [max(v.co[i] for v in game.data.vertices) for i in range(3)]},
            'bounds_blender_z_up': {'min': [min(v.co[i] for v in mesh.vertices) for i in range(3)],
                                    'max': [max(v.co[i] for v in mesh.vertices) for i in range(3)]}}
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print('MASSIF_VALIDATED ' + json.dumps(manifest), flush=True)
