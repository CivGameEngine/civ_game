"""UV и запечённый PBR горного массива. Фазы вызываются через Blender MCP.

load_source_scene(), prepare(), author_material(), start_job(); состояние — в job.json.
Серый исходник не перезаписывается, текущая пользовательская сцена сохраняется.
"""
import bpy
import json
import math
import traceback
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'art/landscape/massifs'
OUT = BASE / 'textured_v1'
SCENE = 'Mountain_Massif_Textured_v1'
MODEL = 'mountain_massif_9hex_textured_v1'

def status(phase, **values):
    (OUT / 'source/job.json').write_text(json.dumps({'phase': phase, **values}, indent=2), encoding='utf-8')
    print('MASSIF_TEXTURE', phase, flush=True)

def model():
    return bpy.data.objects[MODEL]

def load_source_scene():
    if SCENE not in bpy.data.scenes:
        with bpy.data.libraries.load(str(BASE / 'source/mountain_massif_9hex_v1.blend'), link=False) as (source, target):
            target.scenes = ['Mountain_Massif_9_Hex_Clay']
        target.scenes[0].name = SCENE
    bpy.context.window.scene = bpy.data.scenes[SCENE]

def select_model():
    bpy.context.window.scene = bpy.data.scenes[SCENE]
    bpy.ops.object.select_all(action='DESELECT')
    obj = model()
    obj.hide_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    return obj

def prepare():
    scene = bpy.data.scenes[SCENE]
    bpy.context.window.scene = scene
    obj = bpy.data.objects.get(MODEL)
    if obj is None:
        high = next(o for o in scene.objects if o.type == 'MESH')
        high.name = 'HighPoly_Clay_Archive'
        high.hide_render = True
        high.hide_viewport = True
        high.hide_set(True)
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=str(BASE / 'models/mountain_massif_9hex_v1.glb'))
        imported = [o for o in bpy.data.objects if o not in before and o.type == 'MESH']
        assert len(imported) == 1
        obj = imported[0]
        obj.name = MODEL
    select_model()
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.data.materials.clear()
    for layer in list(obj.data.uv_layers):
        obj.data.uv_layers.remove(layer)
    obj.data.uv_layers.new(name='Massif_UV')
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(72), island_margin=.004, area_weight=.1)
    bpy.ops.object.mode_set(mode='OBJECT')
    uv = obj.data.uv_layers.active
    assert uv and all(math.isfinite(float(value)) and -.0001 <= value <= 1.0001 for item in uv.data for value in item.uv)
    obj['notes'] = '9 гексов; UV/PBR; геометрия из серого GLB; к игровой карте не подключён.'
    for area in bpy.context.screen.areas:
        if area.type == 'VIEW_3D':
            area.spaces.active.shading.type = 'MATERIAL'
    status('uv_ready', triangles=sum(len(p.vertices) - 2 for p in obj.data.polygons), uv_loops=len(uv.data))

def node(nodes, kind, label):
    value = nodes.new(kind)
    value.label = label
    return value

def author_material():
    obj = select_model()
    mat = bpy.data.materials.new('Massif_Authoring_Triplanar_Snow')
    mat.use_nodes = True
    mat.use_fake_user = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    output = node(nodes, 'ShaderNodeOutputMaterial', 'Выход')
    bsdf = node(nodes, 'ShaderNodeBsdfPrincipled', 'Скала и снег')
    links.new(bsdf.outputs[0], output.inputs['Surface'])
    bsdf.inputs['Specular IOR Level'].default_value = .25
    coordinates = node(nodes, 'ShaderNodeTexCoord', 'Координаты объекта в метрах')
    mapping = node(nodes, 'ShaderNodeVectorMath', 'Масштаб скальной текстуры')
    mapping.operation = 'SCALE'
    mapping.inputs['Scale'].default_value = 1.2
    links.new(coordinates.outputs['Object'], mapping.inputs[0])
    rock = node(nodes, 'ShaderNodeTexImage', 'Сгенерированная скала')
    rock.image = bpy.data.images.load(str(OUT / 'textures/rock_generated_albedo.png'), check_existing=True)
    rock.image.pack()
    allowed = [item.identifier for item in rock.bl_rna.properties['projection'].enum_items]
    rock.projection = next(value for value in allowed if value == 'BOX')
    rock.projection_blend = .28
    links.new(mapping.outputs['Vector'], rock.inputs['Vector'])
    geometry = node(nodes, 'ShaderNodeNewGeometry', 'Положение и наклон поверхности')
    position = node(nodes, 'ShaderNodeSeparateXYZ', 'Высота')
    normal = node(nodes, 'ShaderNodeSeparateXYZ', 'Вертикаль нормали')
    links.new(geometry.outputs['Position'], position.inputs[0])
    links.new(geometry.outputs['Normal'], normal.inputs[0])
    patch = node(nodes, 'ShaderNodeTexNoise', 'Неровная граница снега')
    patch.inputs['Scale'].default_value = 4.5
    patch.inputs['Detail'].default_value = 3
    links.new(coordinates.outputs['Object'], patch.inputs['Vector'])

    def remap(source, minimum, maximum, label):
        result = node(nodes, 'ShaderNodeMapRange', label)
        result.clamp = True
        result.inputs['From Min'].default_value = minimum
        result.inputs['From Max'].default_value = maximum
        links.new(source, result.inputs['Value'])
        return result.outputs[0]

    def multiply(a, b, label):
        result = node(nodes, 'ShaderNodeMath', label)
        result.operation = 'MULTIPLY'
        links.new(a, result.inputs[0])
        links.new(b, result.inputs[1])
        return result.outputs[0]

    altitude = remap(position.outputs['Z'], .85, 1.9, 'Снег выше подножия')
    slope = remap(normal.outputs['Z'], .28, .77, 'Снег на пологих склонах')
    patches = remap(patch.outputs['Fac'], .32, .66, 'Островки снега')
    mask = multiply(multiply(altitude, slope, 'Высота × наклон'), patches, 'Маска снега')
    snow = node(nodes, 'ShaderNodeValToRGB', 'Граница скала — снег')
    snow.color_ramp.elements[0].position = .12
    snow.color_ramp.elements[1].position = .48
    links.new(mask, snow.inputs[0])
    color = node(nodes, 'ShaderNodeMixRGB', 'Итоговый цвет для запекания')
    color.name = 'Massif_BaseColor_ToBake'
    color.inputs[2].default_value = (.72, .76, .80, 1)
    links.new(snow.outputs['Color'], color.inputs[0])
    links.new(rock.outputs['Color'], color.inputs[1])
    links.new(color.outputs[0], bsdf.inputs['Base Color'])
    rough = node(nodes, 'ShaderNodeMapRange', 'Шероховатость камня')
    rough.name = 'Massif_Roughness_ToBake'
    rough.inputs['From Min'].default_value = 0
    rough.inputs['From Max'].default_value = 1
    rough.inputs['To Min'].default_value = .78
    rough.inputs['To Max'].default_value = .96
    links.new(patch.outputs['Fac'], rough.inputs['Value'])
    links.new(rough.outputs[0], bsdf.inputs['Roughness'])
    bump = node(nodes, 'ShaderNodeBump', 'Микрорельеф из скальной текстуры')
    bump.inputs['Strength'].default_value = .16
    bump.inputs['Distance'].default_value = .022
    links.new(rock.outputs['Color'], bump.inputs['Height'])
    links.new(bump.outputs[0], bsdf.inputs['Normal'])
    obj.data.materials.append(mat)
    # Раскладываем узлы, чтобы материал было удобно редактировать вручную.
    for index, item in enumerate(nodes):
        item.location = ((index % 5) * 260, -(index // 5) * 250)
    status('material_ready', source_image_size=list(rock.image.size))

def render(name, location, target=(.6, 0, 1.05), span=8.6):
    scene = bpy.data.scenes[SCENE]
    camera = scene.camera
    camera.location = location
    camera.rotation_euler = (Vector(target) - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.ortho_scale = span
    scene.render.filepath = str(OUT / 'previews' / name)
    scene.cycles.samples = 32
    bpy.ops.render.render(write_still=True)

def bake_map(kind, source_socket=None):
    obj = select_model()
    scene = bpy.data.scenes[SCENE]
    scene.cycles.samples = 8
    scene.render.bake.margin = 8
    scene.render.bake.use_selected_to_active = False
    mat = obj.active_material
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    size = 4096 if kind == 'albedo' else 2048
    image = bpy.data.images.new('Massif_Baked_' + kind, width=size, height=size, alpha=False)
    image.colorspace_settings.name = 'sRGB' if kind == 'albedo' else 'Non-Color'
    target = node(nodes, 'ShaderNodeTexImage', 'Запекание ' + kind)
    target.image = image
    for item in nodes:
        item.select = False
    target.select = True
    nodes.active = target
    output = next(item for item in nodes if item.type == 'OUTPUT_MATERIAL')
    bsdf = next(item for item in nodes if item.type == 'BSDF_PRINCIPLED')
    if source_socket is not None:
        emission = node(nodes, 'ShaderNodeEmission', 'Запекание без освещения')
        links.new(source_socket, emission.inputs['Color'])
        links.new(emission.outputs[0], output.inputs['Surface'])
        bpy.ops.object.bake(type='EMIT')
        nodes.remove(emission)
        links.new(bsdf.outputs[0], output.inputs['Surface'])
    else:
        bpy.ops.object.bake(type='NORMAL')
    image.filepath_raw = str(OUT / 'textures' / ('massif_' + kind + '.png'))
    image.file_format = 'PNG'
    image.save()
    image.pack()
    nodes.remove(target)
    return image

def bake_and_export():
    obj = select_model()
    author = obj.active_material
    status('baking_albedo')
    albedo = bake_map('albedo', author.node_tree.nodes['Massif_BaseColor_ToBake'].outputs[0])
    status('baking_roughness')
    roughness = bake_map('roughness', author.node_tree.nodes['Massif_Roughness_ToBake'].outputs[0])
    status('baking_normal')
    normal = bake_map('normal')
    mat = bpy.data.materials.new('Massif_PBR_Baked_UV')
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = next(item for item in nodes if item.type == 'BSDF_PRINCIPLED')
    bsdf.inputs['Specular IOR Level'].default_value = .25
    for image, label, socket in [(albedo, 'Albedo 4K', 'Base Color'), (roughness, 'Roughness 2K', 'Roughness')]:
        tex = node(nodes, 'ShaderNodeTexImage', label)
        tex.image = image
        links.new(tex.outputs['Color'], bsdf.inputs[socket])
    tex = node(nodes, 'ShaderNodeTexImage', 'Normal 2K')
    tex.image = normal
    normal_map = node(nodes, 'ShaderNodeNormalMap', 'Tangent-space normal')
    links.new(tex.outputs['Color'], normal_map.inputs['Color'])
    links.new(normal_map.outputs['Normal'], bsdf.inputs['Normal'])
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    for index, item in enumerate(nodes):
        item.location = ((index % 3) * 280, -(index // 3) * 260)
    status('rendering_baked')
    render('massif_textured_front.png', (3.2, -10, 5.5))
    render('massif_textured_reverse.png', (-6, 8, 6))
    render('massif_textured_detail.png', (-.4, -4.7, 3.1), (-.6, -.05, 1.4), 3.8)
    # Развёртка — технический SVG, не подмена сгенерированной текстуры.
    uv = obj.data.uv_layers.active
    paths = []
    for polygon in obj.data.polygons:
        points = ' '.join(f'{uv.data[i].uv.x * 2048:.2f},{(1-uv.data[i].uv.y)*2048:.2f}' for i in polygon.loop_indices)
        paths.append('<polygon points="' + points + '"/>')
    (OUT / 'previews/uv_layout.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="2048" height="2048" viewBox="0 0 2048 2048"><rect width="2048" height="2048" fill="#20242b"/><g fill="none" stroke="#85c9c0" stroke-width="0.35">' + ''.join(paths) + '</g></svg>', encoding='utf-8')
    render('massif_textured_top.png', (.6, 0, 14), (.6, 0, 0))
    scene = bpy.data.scenes[SCENE]
    camera = scene.camera
    camera.location = (3.2, -10, 5.5)
    camera.rotation_euler = (Vector((.6, 0, 1.05)) - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.ortho_scale = 8.6
    select_model()
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                area.spaces.active.shading.type = 'MATERIAL'
                area.spaces.active.region_3d.view_location = Vector((.6, 0, 1))
                area.spaces.active.region_3d.view_distance = 10
                area.spaces.active.region_3d.view_rotation = camera.rotation_euler.to_quaternion()
    for image in (albedo, roughness, normal):
        image.filepath = '//../textures/' + Path(image.filepath_raw).name
    bpy.data.images['rock_generated_albedo.png'].filepath = '//../textures/rock_generated_albedo.png'
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'source/mountain_massif_9hex_textured_v1.blend'),
                              copy=True, relative_remap=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=str(OUT / 'models/mountain_massif_9hex_textured_v1.glb'),
                             use_selection=True, use_active_scene=True, export_animations=False,
                             export_cameras=False, export_lights=False)
    source_manifest = json.loads((BASE / 'manifest.json').read_text(encoding='utf-8'))
    source_manifest.update({'id': MODEL, 'source': 'source/mountain_massif_9hex_textured_v1.blend',
                            'model': 'models/mountain_massif_9hex_textured_v1.glb',
                            'textures': ['textures/massif_albedo.png', 'textures/massif_normal.png', 'textures/massif_roughness.png'],
                            'uv_layer': uv.name, 'albedo_size': [4096, 4096], 'normal_roughness_size': [2048, 2048]})
    (OUT / 'manifest.json').write_text(json.dumps(source_manifest, indent=2), encoding='utf-8')
    status('complete', triangles=45000, textures=source_manifest['textures'])

def start_job():
    def run():
        try:
            bake_and_export()
        except Exception:
            status('failed', error=traceback.format_exc())
        return None
    status('scheduled')
    bpy.app.timers.register(run, first_interval=1.0)
    print('Задание запекания запущено; состояние в textured_v1/source/job.json')
