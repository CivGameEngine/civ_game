"""Гастат по front/back hap.jpg: геометрия без текстур, Blender 4.5 / MCP.

Фазы: body(), armor(), equipment(), studio(), start_finish().
Пользовательские сцены не очищаются, исходник сохраняется как копия.
"""
import bpy
import bmesh
import math
import json
import random
import traceback
import sys
from pathlib import Path
from mathutils import Vector, Matrix

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'art/units/rome/hastatus_v1'
SCENE = 'Hastatus_Clay_v1'
ASSETS = 'Hastatus_Assets'
SEED = 23112026
RNG = random.Random(SEED)
STAGE = 'unassigned'

def initialize():
    scene=bpy.data.scenes.get(SCENE)
    if scene is None:
        scene=bpy.data.scenes.new(SCENE)
    bpy.context.window.scene=scene
    scene.unit_settings.system='METRIC'
    if ASSETS not in bpy.data.collections:
        collection=bpy.data.collections.new(ASSETS)
        scene.collection.children.link(collection)
    if 'Hastatus_v1' not in bpy.data.objects:
        root=bpy.data.objects.new('Hastatus_v1',None)
        bpy.data.collections[ASSETS].objects.link(root)

def begin_stage(stage):
    global STAGE
    STAGE = stage
    for obj in list(bpy.data.collections[ASSETS].objects):
        if obj.get('hastatus_stage') == stage or (stage == 'body' and obj.name == 'Body_Posed_Skin'):
            bpy.data.objects.remove(obj, do_unlink=True)

def status(phase, **fields):
    (OUT / 'source/job.json').write_text(json.dumps({'phase': phase, **fields}, indent=2), encoding='utf-8')
    print('HASTATUS', phase, flush=True)

def material():
    mat = bpy.data.materials.get('Hastatus_Neutral_Clay')
    if mat is None:
        mat = bpy.data.materials.new('Hastatus_Neutral_Clay')
        mat.use_nodes = True
        mat.diffuse_color = (.32, .345, .37, 1)
        bsdf = next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
        bsdf.inputs['Base Color'].default_value = mat.diffuse_color
        bsdf.inputs['Roughness'].default_value = .72
        bsdf.inputs['Specular IOR Level'].default_value = .28
    return mat

def mesh(name, vertices, faces, smooth=True):
    data = bpy.data.meshes.new(name + '_Mesh')
    data.from_pydata(vertices, [], faces)
    data.validate(clean_customdata=True)
    bm = bmesh.new()
    bm.from_mesh(data)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(data)
    bm.free()
    data.update()
    obj = bpy.data.objects.new(name, data)
    bpy.data.collections[ASSETS].objects.link(obj)
    obj.parent = bpy.data.objects['Hastatus_v1']
    obj['hastatus_stage'] = STAGE
    data.materials.append(material())
    for polygon in data.polygons:
        polygon.use_smooth = smooth
    return obj

def bevel(obj, amount=.002, segments=2):
    mod = obj.modifiers.new('Soft_Edges', 'BEVEL')
    mod.width = amount
    mod.segments = segments
    return obj

def shell(obj, thickness=.004, rounding=.0015):
    mod = obj.modifiers.new('Real_Thickness', 'SOLIDIFY')
    mod.thickness = thickness
    mod.offset = 0
    mod.use_even_offset = True
    if rounding:
        bevel(obj, rounding, 2)
    return obj

def ellipsoid(name, center, radii, segments=24, rings=14, basis=None):
    basis = basis or Matrix.Identity(3)
    vertices = [Vector(center) + basis @ Vector((0, 0, radii[2]))]
    for ring in range(1, rings):
        latitude = math.pi * ring / rings
        for k in range(segments):
            angle = math.tau * k / segments
            local = Vector((radii[0] * math.sin(latitude) * math.cos(angle),
                            radii[1] * math.sin(latitude) * math.sin(angle),
                            radii[2] * math.cos(latitude)))
            vertices.append(Vector(center) + basis @ local)
    bottom = len(vertices)
    vertices.append(Vector(center) + basis @ Vector((0, 0, -radii[2])))
    faces = [(0, 1 + k, 1 + (k + 1) % segments) for k in range(segments)]
    for ring in range(rings - 2):
        a, b = 1 + ring * segments, 1 + (ring + 1) * segments
        for k in range(segments):
            j = (k + 1) % segments
            faces.append((a + k, b + k, b + j, a + j))
    end = 1 + (rings - 2) * segments
    faces += [(bottom, end + (k + 1) % segments, end + k) for k in range(segments)]
    return mesh(name, vertices, faces)

def catmull(a, b, c, d, t):
    return .5 * ((2*b) + (-a+c)*t + (2*a-5*b+4*c-d)*t*t + (-a+3*b-3*c+d)*t*t*t)

def loft(name, points, radii, sides=16, samples=3):
    points = [Vector(p) for p in points]
    radii = [Vector(r) for r in radii]
    closed=(points[0]-points[-1]).length < 1e-7
    if closed:
        points.pop()
        radii.pop()
    centers, sizes = [], []
    for i in range(len(points) if closed else len(points)-1):
        for step in range(samples):
            t = step / samples
            ids = ((i-1)%len(points),i,(i+1)%len(points),(i+2)%len(points)) if closed else (max(0,i-1),i,i+1,min(len(points)-1,i+2))
            centers.append(catmull(*(points[k] for k in ids), t))
            sizes.append(catmull(*(radii[k] for k in ids), t))
    if not closed:
        centers.append(points[-1])
        sizes.append(radii[-1])
    vertices, faces = [], []
    previous_u=None
    for i, (center, radius) in enumerate(zip(centers, sizes)):
        following=(i+1)%len(centers) if closed else min(i+1,len(centers)-1)
        preceding=(i-1)%len(centers) if closed else max(0,i-1)
        tangent=(centers[following]-centers[preceding]).normalized()
        if previous_u is None:
            guide=Vector((0,1,0))
            if abs(tangent.dot(guide))>.96:
                guide=Vector((1,0,0))
            u=tangent.cross(guide).normalized()
        else:
            # Параллельный перенос сечения без внезапного поворота на 90°.
            u=(previous_u-tangent*previous_u.dot(tangent)).normalized()
        previous_u=u
        v = tangent.cross(u).normalized()
        for k in range(sides):
            angle = math.tau * k / sides
            vertices.append(center + u * radius.x * math.cos(angle) + v * radius.y * math.sin(angle))
    for i in range(len(centers) if closed else len(centers)-1):
        following=(i+1)%len(centers)
        for k in range(sides):
            j = (k+1) % sides
            faces.append((i*sides+k, following*sides+k, following*sides+j, i*sides+j))
    if not closed:
        faces.append(tuple(reversed(range(sides))))
        faces.append(tuple((len(centers)-1)*sides+k for k in range(sides)))
    return mesh(name, vertices, faces)

def tube(name, points, radius=.002, sides=8):
    radii = [(radius, radius)] * len(points) if isinstance(radius, (float, int)) else [(r, r) for r in radius]
    return loft(name, points, radii, sides, 2)

def ribbon(name, points, width=.014, normal=(0, -1, 0), thickness=.003):
    vertices, faces = [], []
    points = [Vector(p) for p in points]
    for i, point in enumerate(points):
        tangent = (points[min(i+1, len(points)-1)] - points[max(0, i-1)]).normalized()
        side = tangent.cross(Vector(normal)).normalized()
        vertices.extend((point-side*width/2, point+side*width/2))
    for i in range(len(points)-1):
        faces.append((i*2, i*2+1, i*2+3, i*2+2))
    return shell(mesh(name, vertices, faces), thickness, .0008)

def ellipse_points(rx, ry, z, center=(0, 0), count=64, start=0, end=math.tau):
    return [(center[0]+rx*math.sin(start+(end-start)*i/count),
             center[1]-ry*math.cos(start+(end-start)*i/count), z) for i in range(count+1)]

def join(objects, name):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    result = bpy.context.object
    result.name = name
    return result

def body():
    bpy.context.window.scene = bpy.data.scenes[SCENE]
    begin_stage('body')
    before = set(bpy.data.objects)
    loft('Skin_Torso', [(0,0,.92),(0,0,1.05),(0,0,1.18),(0,0,1.36),(0,.012,1.46),(0,.015,1.51)],
         [(.145,.105),(.16,.10),(.175,.11),(.205,.12),(.22,.105),(.14,.08)], 32)
    ellipsoid('Skin_Pelvis',(0,.025,.96),(.17,.12,.12))
    loft('Skin_Neck',[(0,.016,1.44),(0,.014,1.52),(0,.01,1.59)],[ (.082,.072),(.064,.064),(.067,.067)],20)
    loft('Skin_Head',[(0,-.007,1.555),(0,-.001,1.59),(0,.009,1.67),(0,.012,1.74),(0,.018,1.79),(0,.02,1.81)],
         [(.04,.055),(.072,.075),(.098,.094),(.095,.092),(.065,.07),(.01,.012)],32)
    ellipsoid('Skin_Nose',(0,-.09,1.675),(.019,.035,.033))
    for side in (-1,1):
        ellipsoid('Skin_Ear', (side*.098,.008,1.686),(.018,.022,.037))
    loft('Skin_Arm_R',[(-.20,0,1.46),(-.27,-.007,1.435),(-.34,-.025,1.35),(-.385,-.035,1.30),
                       (-.397,-.07,1.39),(-.390,-.11,1.53),(-.372,-.133,1.615)],
         [(.067,.073),(.072,.075),(.061,.063),(.044,.05),(.053,.051),(.038,.034),(.023,.025)],24)
    loft('Skin_Arm_L',[(.20,0,1.46),(.265,.005,1.41),(.31,-.005,1.32),(.334,-.017,1.245),
                       (.39,-.032,1.18),(.46,-.040,1.105),(.51,-.034,1.075)],
         [(.068,.071),(.073,.071),(.062,.064),(.046,.049),(.052,.05),(.033,.030),(.023,.025)],24)
    loft('Skin_Palm_R',[(-.373,-.132,1.604),(-.385,-.135,1.642),(-.378,-.139,1.695)],
         [(.024,.021),(.031,.020),(.026,.018)],16)
    # Четыре пальца обхватывают древко, большой палец противопоставлен им.
    for index,z in enumerate((1.631,1.650,1.669,1.687)):
        shaft_x = -.20 - .27 * z / 2.68
        shaft_y = -.20 + .10 * z / 2.68
        tube('Skin_Finger_R',[(shaft_x-.025,shaft_y+.012,z),(shaft_x-.027,shaft_y-.017,z+.003),
                             (shaft_x-.003,shaft_y-.028,z+.002),(shaft_x+.017,shaft_y-.016,z-.002),
                             (shaft_x+.013,shaft_y+.002,z-.004)], [.0065,.007,.0065,.0055,.0048],12)
    tube('Skin_Thumb_R',[(-.395,-.123,1.685),(-.363,-.149,1.708),(-.349,-.164,1.685),(-.366,-.170,1.669)],
         [.012,.011,.009,.0075],12)
    loft('Skin_Palm_L',[(.505,-.035,1.078),(.535,-.036,1.08),(.58,-.034,1.08)],
         [(.022,.023),(.022,.03),(.017,.025)],16)
    for x in (.539,.555,.571,.587):
        tube('Skin_Finger_L',[(x,-.021,1.102),(x,-.049,1.092),(x,-.05,1.070),(x,-.027,1.055),(x,-.008,1.068)],
             [.0065,.0068,.0065,.0055,.0045],12)
    tube('Skin_Thumb_L',[(.539,-.040,1.10),(.568,-.057,1.115),(.594,-.047,1.105),(.601,-.022,1.087)],
         [.011,.010,.008,.007],12)
    for side in (-1,1):
        x = -.12 if side < 0 else .15
        y = -.025 if side < 0 else .045
        loft('Skin_Leg',[(side*.105,.02,.97),(side*.12,.025,.84),(x,y,.68),(x,y,.56),
                         (x,y,.49),(x,y+.016,.36),(x,y+.012,.22),(x,y,.125)],
             [(.085,.088),(.096,.09),(.078,.073),(.056,.063),(.054,.06),(.064,.058),(.042,.04),(.03,.033)],24)
        ellipsoid('Skin_Knee',(x,y-.018,.56),(.055,.061,.065))
        angle = math.radians(18 if side > 0 else -4)
        rotation = Matrix.Rotation(angle,3,'Z')
        center = Vector((x,y-.065,.062))
        ellipsoid('Skin_Foot',center,(.048,.125,.045),28,16,rotation)
        ellipsoid('Skin_Instep',(x,y-.012,.09),(.039,.064,.052),24,14,rotation)
        for toe in range(5):
            lateral = (.031-toe*.016) * (1 if side < 0 else -1)
            local = Vector((lateral,-.168+abs(toe-1)*.004,.048))
            p = Vector((x,y,0))+rotation@local
            ellipsoid('Skin_Toe',p,(.0105 if toe else .013,.024 if toe else .028,.019),14,10,rotation)
    parts = [o for o in bpy.data.objects if o not in before and o.type=='MESH']
    skin = join(parts,'Body_Posed_Skin')
    remesh = skin.modifiers.new('Continuous_Anatomy','REMESH')
    allowed = [i.identifier for i in remesh.bl_rna.properties['mode'].enum_items]
    remesh.mode = next(i for i in allowed if i=='VOXEL')
    remesh.voxel_size = .0032
    remesh.use_smooth_shade = True
    bpy.ops.object.modifier_apply(modifier=remesh.name)
    smooth = skin.modifiers.new('Skin_Soften','SMOOTH')
    smooth.factor=.6
    smooth.iterations=3
    bpy.ops.object.modifier_apply(modifier=smooth.name)
    for p in skin.data.polygons:
        p.use_smooth=True
    status('body_ready', polygons=len(skin.data.polygons))

def armor():
    begin_stage('armor')
    RNG.seed(SEED)
    # Ткань под панцирем и свободная юбка со складками.
    vertices, faces = [], []
    count, rings = 96, 13
    for ring in range(rings):
        t = ring / (rings-1)
        z = 1.07 - .34*t
        for k in range(count):
            a = math.tau*k/count
            fold = (.003 + .013*t) * (math.sin(22*a+.3*t)+.25*math.sin(44*a))
            rx, ry = .17+.081*t+fold, .115+.055*t+fold*.8
            vertices.append((rx*math.sin(a),-ry*math.cos(a),z+.009*t*t*math.sin(5*a+.3)))
    for ring in range(rings-1):
        for k in range(count):
            j=(k+1)%count
            faces.append((ring*count+k,ring*count+j,(ring+1)*count+j,(ring+1)*count+k))
    shell(mesh('Garment_Pleated_Tunic',vertices,faces),.004,.001)
    # Основание чешуйчатого панциря.
    torso = loft('Armor_Cuirass_Foundation',[(0,0,1.047),(0,0,1.16),(0,0,1.30),(0,0,1.38)],
                 [(.181,.118),(.197,.126),(.215,.13),(.213,.129)],64)
    # Каждая чешуйка имеет объём и скруглённое нижнее ребро.
    vertices, faces = [], []
    outline=[(-.5,.5),(.5,.5),(.5,-.08),(.38,-.36),(.16,-.49),(0,-.52),(-.16,-.49),(-.38,-.36),(-.5,-.08)]
    for row in range(8):
        z=1.307-row*.034
        rx=.182+(z-1.05)/.26*.032
        ry=.119+(z-1.05)/.26*.012
        for col in range(34):
            a=math.tau*(col+.5*(row%2))/34
            outward=Vector((math.sin(a)/rx,-math.cos(a)/ry,0)).normalized()
            tangent=Vector((rx*math.cos(a),ry*math.sin(a),0)).normalized()
            center=Vector((rx*math.sin(a),-ry*math.cos(a),z))+outward*.0035
            width, height=.036,.049
            start=len(vertices)
            vertices.append(center+outward*.0024)
            vertices += [center+tangent*(u*width)+Vector((0,0,v*height)) for u,v in outline]
            back=len(vertices)
            vertices += [center+tangent*(u*width)+Vector((0,0,v*height))-outward*.002 for u,v in outline]
            n=len(outline)
            for k in range(n):
                j=(k+1)%n
                faces.append((start,start+1+k,start+1+j))
                faces.append((start+1+k,back+k,back+j,start+1+j))
            faces.append(tuple(back+k for k in reversed(range(n))))
    bevel(mesh('Armor_Individual_Scales',vertices,faces,False),.00045,2)
    # Белый верхний корсет и плечевые клапаны — отдельные пластины.
    loft('Armor_Upper_Corset',[(0,0,1.303),(0,0,1.36),(0,.01,1.46)],
         [(.216,.132),(.217,.132),(.205,.113)],64)
    for side in (-1,1):
        points=[(side*.022,-.149,1.334),(side*.165,-.149,1.334),
                (side*.208,-.149,1.476),(side*.152,-.149,1.525),(side*.055,-.149,1.512)]
        shell(mesh('Armor_Shoulder_Flap',points,[tuple(range(len(points)))],False),.006,.004)
        edging=[(x,y-.005,z) for x,y,z in points]
        tube('Armor_Shoulder_Flap_Edging',edging+[edging[0]],.0033,10)
        ribbon('Armor_Shoulder_Overstrap',[(side*.129,-.149,1.485),(side*.147,-.085,1.54),
               (side*.15,.005,1.555),(side*.145,.093,1.528),(side*.128,.146,1.48)],.105,(side*.1,0,1),.005)
        ellipsoid('Armor_Shoulder_Rivet',(side*.115,-.156,1.355),(.007,.003,.007),18,10)
    points=[(-.181,.145,1.345),(.181,.145,1.345),(.213,.145,1.493),(.11,.145,1.53),
            (.072,.145,1.473),(-.072,.145,1.473),(-.11,.145,1.53),(-.213,.145,1.493)]
    shell(mesh('Armor_Back_Yoke',points,[tuple(range(len(points)))],False),.006,.003)
    edging=[(x,y+.005,z) for x,y,z in points]
    tube('Armor_Back_Yoke_Edging',edging+[edging[0]],.003,10)
    # Кожаные/льняные птеруги по всему поясу.
    for strip in range(20):
        a=math.tau*strip/20
        vertices, faces=[],[]
        for ring in range(5):
            t=ring/4
            for k in range(5):
                u=k/4
                angle=a+(u-.5)*math.tau/20*.91
                z=1.056-.198*t
                if ring==4:
                    z += .009*(2*u-1)**4 + .007*math.sin(a*3)
                rx=.191+.035*t
                ry=.128+.026*t
                vertices.append((rx*math.sin(angle),-ry*math.cos(angle),z))
        for ring in range(4):
            for k in range(4):
                i=ring*5+k
                faces.append((i,i+1,i+6,i+5))
        shell(mesh('Armor_Pteruges_%02d'%strip,vertices,faces),.0045,.0018)
    for z in (1.044,1.061):
        tube('Armor_Waist_Binding',ellipse_points(.193,.129,z),.003,10)
    # Небольшой шейный платок и ремни на спине.
    loft('Garment_Neck_Wrap',[(0,.01,1.502),(0,.01,1.535),(0,.01,1.565)],
         [(.079,.075),(.073,.072),(.073,.072)],48)
    for z in (1.51,1.544):
        tube('Garment_Collar_Fold',ellipse_points(.076,.076,z,(0,.01)),.0025,8)
    ribbon('Equipment_Back_Baldric',[(-.10,.143,1.48),(-.048,.149,1.38),(.016,.15,1.28),(.074,.142,1.17),(.13,.128,1.07)],.018,(0,1,0),.003)
    ribbon('Equipment_Back_Second_Strap',[(.12,.136,1.48),(.07,.148,1.39),(.014,.15,1.29),(-.043,.142,1.17),(-.108,.128,1.06)],.009,(0,1,0),.002)
    # Цепочка и медальон моделируются геометрией.
    for side in (-1,1):
        tube('Equipment_Neck_Chain',[(side*.063,-.087,1.56),(side*.076,-.141,1.48),(side*.045,-.153,1.37),(0,-.153,1.255)],.0016,8)
    disk_basis=Matrix.Rotation(math.pi/2,3,'X')
    ellipsoid('Equipment_Medallion',(0,-.154,1.251),(.018,.018,.004),32,12,disk_basis)
    ellipsoid('Equipment_Medallion_Boss',(0,-.161,1.251),(.007,.007,.003),20,10,disk_basis)
    # Поножи закрывают переднюю и боковую части голени, с ремнями сзади.
    for side in (-1,1):
        x=-.12 if side<0 else .15
        y=-.025 if side<0 else .045
        heights=[.14,.19,.28,.37,.46,.52,.558]
        widths=[.038,.045,.062,.071,.065,.061,.054]
        depths=[.038,.044,.059,.067,.067,.064,.052]
        vertices, faces=[],[]
        columns=25
        for row,z in enumerate(heights):
            for k in range(columns):
                a=math.radians(-108+216*k/(columns-1))
                ridge=.006*math.exp(-a*a/.07)
                zz=z+(.018*math.cos(a) if row==len(heights)-1 else 0)
                vertices.append((x+widths[row]*math.sin(a),y-depths[row]*math.cos(a)-ridge,zz))
        for row in range(len(heights)-1):
            for k in range(columns-1):
                i=row*columns+k
                faces.append((i,i+1,i+columns+1,i+columns))
        shell(mesh('Armor_Greave_R' if side<0 else 'Armor_Greave_L',vertices,faces),.004,.0015)
        boundary=vertices[:columns]+[vertices[row*columns+columns-1] for row in range(1,len(heights))]+list(reversed(vertices[-columns:-1]))+[vertices[row*columns] for row in reversed(range(1,len(heights)-1))]
        tube('Armor_Greave_Edge',boundary+[boundary[0]],.0027,8)
        for z,r in ((.225,.052),(.455,.066)):
            path=ellipse_points(r,r*.94,z,(x,y),32)
            ribbon('Armor_Greave_Retention_Strap',path,.013,(0,0,1),.0025)
        for z in (.108,.126):
            tube('Garment_Ankle_Wrap',ellipse_points(.038,.041,z,(x,y)),.0034,8)
    helmet()
    sandals()
    status('armor_ready')

def helmet():
    vertices,faces=[],[]
    segments,rings=80,20
    vertices.append((0,.013,1.875))
    for row in range(1,rings+1):
        t=row/rings
        for k in range(segments):
            a=math.tau*k/segments
            rim=1.685+.039*math.cos(a)
            end=math.acos(max(-1,min(1,(rim-1.69)/.185)))
            latitude=end*t
            vertices.append((.125*math.sin(latitude)*math.sin(a),
                             .013-.145*math.sin(latitude)*math.cos(a),1.69+.185*math.cos(latitude)))
    for k in range(segments):
        faces.append((0,1+k,1+(k+1)%segments))
    for row in range(rings-1):
        for k in range(segments):
            j=(k+1)%segments
            a,b=1+row*segments,1+(row+1)*segments
            faces.append((a+k,a+j,b+j,b+k))
    shell(mesh('Helmet_Domed_Shell',vertices,faces),.004,.001)
    edge=vertices[1+(rings-1)*segments:]
    tube('Helmet_Lower_Rolled_Rim',edge+[edge[0]],.0038,10)
    for side in (-1,1):
        points=[(side*.102,-.094,1.716),(side*.126,-.028,1.69),(side*.128,.035,1.64),
                (side*.079,-.111,1.535),(side*.024,-.153,1.572),(side*.033,-.149,1.677),(side*.073,-.137,1.687)]
        shell(mesh('Helmet_Cheek_Guard_R' if side<0 else 'Helmet_Cheek_Guard_L',points,[tuple(range(len(points)))],False),.004,.0025)
        tube('Helmet_Cheek_Rolled_Edge',points+[points[0]],.0023,8)
        eye=[(side*.027,-.151,1.713),(side*.048,-.152,1.727),(side*.082,-.134,1.722),
             (side*.097,-.115,1.706),(side*.072,-.138,1.695),(side*.040,-.15,1.697)]
        tube('Helmet_Eye_Opening_Rim',eye+[eye[0]],.0028,10)
    nasal=[(-.018,-.151,1.73),(.018,-.151,1.73),(.012,-.177,1.642),
           (0,-.184,1.628),(-.012,-.177,1.642)]
    shell(mesh('Helmet_Nasal_Plate',nasal,[tuple(range(len(nasal)))],False),.004,.001)
    tube('Helmet_Nasal_Ridge',[(0,-.156,1.732),(0,-.174,1.68),(0,-.184,1.638)],.0019,8)
    # Затылочный козырёк.
    neck=[]
    for k in range(25):
        a=math.pi*.5+math.pi*k/24
        neck.append((.132*math.sin(a),.015-.148*math.cos(a),1.657+.012*abs(math.sin(a))))
    lower=[(x*1.06,y*1.10,z-.042) for x,y,z in neck]
    shell(mesh('Helmet_Nape_Guard',neck+lower,[(k,k+1,25+k+1,25+k) for k in range(24)]),.004,.0015)
    # Гребень в сагиттальной плоскости и пряди конского волоса.
    holder=[(0,-.139+.32*i/20,1.866+.037*math.sin(math.pi*i/20)) for i in range(21)]
    loft('Helmet_Crest_Holder',holder,[(.017,.012)]*len(holder),12,1)
    before=set(bpy.data.objects)
    # Объёмный веер со сплошной основой и продольными бороздами, не щётка
    # из отдельных длинных игл. Текстуры и системы частиц не используются.
    vertices,faces=[],[]
    columns,rows=385,19
    def fan_point(u,v,side):
        base_y=-.139+.32*u
        base_z=1.867+.037*math.sin(math.pi*u)
        a=-math.pi/2+math.pi*u
        top_y=.015+.27*math.sin(a)
        top_z=1.94+.205*math.cos(a)+.003*math.sin(u*math.tau*91)
        groove=.0018*math.sin(u*math.tau*96+.3*v)*math.sin(math.pi*v)
        return (side*(.016+.026*v+groove),base_y*(1-v)+top_y*v,base_z*(1-v)+top_z*v)
    for side in (-1,1):
        for row in range(rows):
            for col in range(columns):
                vertices.append(fan_point(col/(columns-1),row/(rows-1),side))
    section=columns*rows
    for offset in (0,section):
        for row in range(rows-1):
            for col in range(columns-1):
                i=offset+row*columns+col
                faces.append((i,i+1,i+columns+1,i+columns))
    for col in range(columns-1):
        a,b=col,col+1
        faces.append((a,b,section+b,section+a))
        a,b=(rows-1)*columns+col,(rows-1)*columns+col+1
        faces.append((a,section+a,section+b,b))
    for row in range(rows-1):
        for col in (0,columns-1):
            a,b=row*columns+col,(row+1)*columns+col
            faces.append((a,section+a,section+b,b))
    mesh('Crest_Sculpted_Horsehair_Fan',vertices,faces)
    for index in range(240):
        u=(index+.5)/240
        side=RNG.choice((-1,1))
        points=[fan_point(u,.89,side),fan_point(u,.965,side),fan_point(u,1.005+RNG.uniform(0,.018),side)]
        tube('Crest_Outer_Hair_Fringe',points,[.0015,.0013,.0003],5)
    for index in range(110):
        u=index/109
        x=(u-.5)*.069
        jitter=RNG.uniform(-.004,.004)
        points=[(x,.115+jitter,2.002+RNG.uniform(-.01,.01)),(x*1.1,.178+jitter,1.944),
                (x*.9,.20+jitter,1.824),(x*.8,.19+jitter,1.701),(x*.65,.175+jitter,1.56),
                (x*.6,.17+jitter,1.435+RNG.uniform(-.025,.025))]
        tube('Crest_Hanging_Mane',points,[.0018,.0018,.0017,.0016,.0013,.0005],6)
    hairs=[o for o in bpy.data.objects if o not in before and o.type=='MESH']
    join(hairs,'Helmet_Horsehair_Crest')
    # Рельефные треугольники основания — без цветной окраски.
    for side in (-1,1):
        for index in range(8):
            u=(index+.5)/8
            y=-.12+.27*u
            z=1.865+.037*math.sin(math.pi*u)
            points=[(side*.019,y-.015,z),(side*.019,y+.015,z),(side*.019,y,z+.026)]
            shell(mesh('Helmet_Crest_Base_Triangle',points,[(0,1,2)],False),.002,.0005)

def sandals():
    for side in (-1,1):
        x=-.12 if side<0 else .15
        y=-.025 if side<0 else .045
        rotation=Matrix.Rotation(math.radians(18 if side>0 else -4),3,'Z')
        def point(p):
            return Vector((x,y,0))+rotation@Vector(p)
        outline=[(-.029,.065),(.031,.065),(.043,.025),(.045,-.045),(.057,-.115),
                 (.054,-.183),(.029,-.202),(-.022,-.199),(-.046,-.181),(-.047,-.115),(-.035,-.035)]
        vertices=[point((a,b,z)) for z in (.012,.032) for a,b in outline]
        n=len(outline)
        faces=[tuple(reversed(range(n))),tuple(n+k for k in range(n))]
        faces += [(k,(k+1)%n,(k+1)%n+n,k+n) for k in range(n)]
        bevel(mesh('Sandals_Sole',vertices,faces),.005,3)
        for points in [
            [(-.045,-.15,.053),(-.03,-.12,.095),(0,-.08,.115),(.04,-.045,.059)],
            [(.047,-.145,.052),(.031,-.112,.096),(0,-.07,.115),(-.036,-.025,.069)],
            [(-.03,.045,.047),(-.038,.052,.091),(0,.04,.127),(.035,.025,.094),(.038,-.015,.055)]]:
            ribbon('Sandals_Leather_Straps',[point(p) for p in points],.013,(0,0,1),.0035)
        tube('Sandals_Ankle_Lace',[point(p) for p in [(-.033,.025,.12),(-.035,-.017,.13),(0,-.037,.132),(.035,-.017,.13),(.033,.025,.12)]],.0027,8)

def equipment():
    begin_stage('equipment')
    center=Vector((.60,.065,1.08))
    radius=.41
    vertices,faces=[],[]
    segments,rings=96,14
    # Две поверхности щита: наружная выпуклая и внутренняя вогнутая.
    for side in (0,1):
        offset=len(vertices)
        vertices.append(center+Vector((0,.080-side*.014,0)))
        for row in range(1,rings+1):
            r=radius*row/rings
            y=.080*(1-(r/radius)**2)-side*.014
            for k in range(segments):
                a=math.tau*k/segments
                vertices.append(center+Vector((r*math.cos(a),y,r*math.sin(a))))
        for k in range(segments):
            faces.append((offset,offset+1+k,offset+1+(k+1)%segments))
        for row in range(rings-1):
            a,b=offset+1+row*segments,offset+1+(row+1)*segments
            for k in range(segments):
                j=(k+1)%segments
                faces.append((a+k,a+j,b+j,b+k))
    section=1+rings*segments
    outer=1+(rings-1)*segments
    inner=section+outer
    for k in range(segments):
        j=(k+1)%segments
        faces.append((outer+k,inner+k,inner+j,outer+j))
    shield=mesh('Shield_True_Circular_Bowl',vertices,faces)
    shield['radius_m']=radius
    shield['front_normal_blender']=[0,1,0]
    shield['notes']='Круглый щит: +Y наружная сторона, -Y внутренняя. Сова предназначена для будущей окраски.'
    for r,y,t in ((radius,.0,.008),(.38,-.003,.0035)):
        path=[center+Vector((r*math.cos(math.tau*k/96),y,r*math.sin(math.tau*k/96))) for k in range(97)]
        tube('Shield_Rolled_Rim',path,t,12)
    # Умбон и крепления снаружи; спереди персонажа видна только внутренняя чаша.
    ellipsoid('Shield_Outer_Boss',center+Vector((0,.084,0)),(.055,.023,.055),32,18)
    for k in range(24):
        a=math.tau*k/24
        p=center+Vector((.389*math.cos(a),.012,.389*math.sin(a)))
        ellipsoid('Shield_Rim_Rivet',p,(.0038,.003,.0038),12,8)
    # Рукоять находится перед внутренней поверхностью, пальцы её обхватывают.
    tube('Shield_Handgrip',[(.492,-.012,1.08),(.647,-.012,1.08)],.0088,16)
    for x in (.491,.648):
        tube('Shield_Grip_Standoff',[(x,-.012,1.08),(x,.115,1.08)],.006,12)
        ribbon('Shield_Grip_Mount',[(x,.112,1.025),(x,.119,1.08),(x,.112,1.135)],.026,(0,-1,0),.004)
        for z in (1.033,1.127):
            ellipsoid('Shield_Grip_Rivet',(x,.105,z),(.004,.003,.004),12,8)
    path=[(.443,.112,1.21),(.443,.020,1.205),(.443,-.075,1.17),
          (.443,-.084,1.135),(.443,-.060,1.095),(.443,.020,1.045),(.443,.118,1.035)]
    vertices=[]
    for point in path:
        vertices.extend((Vector(point)+Vector((-.0115,0,0)),Vector(point)+Vector((.0115,0,0))))
    shell(mesh('Shield_Forearm_Loop',vertices,[(i*2,i*2+1,i*2+3,i*2+2) for i in range(len(path)-1)]),.003,.0008)
    for x,y,z in (path[0],path[-1]):
        mount=[(x-.018,y,z-.016),(x+.018,y,z-.016),(x+.018,y,z+.016),(x-.018,y,z+.016)]
        shell(mesh('Shield_Forearm_Anchor',mount,[(0,1,2,3)],False),.003,.001)
        ellipsoid('Shield_Forearm_Rivet',(x,y-.004,z),(.004,.003,.004),12,8)
    # Копьё сохраняет положение и наклон скетча.
    butt=Vector((-.20,-.20,.012))
    tip=Vector((-.47,-.10,2.68))
    axis=(tip-butt).normalized()
    blade_base=tip-axis*.244
    shaft=tube('Spear_Wooden_Shaft',[butt,blade_base+axis*.018],[.009,.008],20)
    shaft['axis_from']=list(butt)
    shaft['axis_to']=list(tip)
    tube('Spear_Metal_Socket',[blade_base-axis*.085,blade_base+axis*.025],[.0105,.0095],20)
    tube('Spear_Butt_Ferrule',[butt-axis*.002,butt+axis*.095],[.007,.009],16)
    u=axis.cross(Vector((0,1,0))).normalized()
    v=axis.cross(u).normalized()
    outline=[(-.008,0),(-.026,.070),(0,.244),(.026,.070),(.008,0)]
    vertices=[blade_base+u*x+axis*z for x,z in outline]
    vertices.extend([blade_base+axis*.085+v*.004,blade_base+axis*.085-v*.004])
    faces=[]
    for k in range(5):
        j=(k+1)%5
        faces.extend(((5,k,j),(6,j,k)))
    mesh('Spear_Diamond_Leaf_Head',vertices,faces,False)
    status('equipment_ready')

def studio():
    scene=bpy.data.scenes[SCENE]
    collection=bpy.data.collections.get('Hastatus_Studio')
    if collection is None:
        collection=bpy.data.collections.new('Hastatus_Studio')
        scene.collection.children.link(collection)
    else:
        for obj in list(collection.objects):
            bpy.data.objects.remove(obj,do_unlink=True)
    world=bpy.data.worlds.new('Hastatus_Neutral_Studio')
    world.use_nodes=True
    bg=next(n for n in world.node_tree.nodes if n.type=='BACKGROUND')
    bg.inputs[0].default_value=(.18,.20,.235,1)
    bg.inputs[1].default_value=.35
    scene.world=world
    for name,location,energy,size in [('Key',(-3,-4,5),480,3),
                                      ('Fill',(4,-2,3),150,3),
                                      ('Rim',(1,4,4),520,2)]:
        data=bpy.data.lights.new('Hastatus_'+name,'AREA')
        data.energy,data.shape,data.size=energy,'DISK',size
        obj=bpy.data.objects.new(data.name,data)
        collection.objects.link(obj)
        obj.location=location
        obj.rotation_euler=(Vector((.1,0,1.1))-obj.location).to_track_quat('-Z','Y').to_euler()
    data=bpy.data.cameras.new('Hastatus_Camera')
    camera=bpy.data.objects.new(data.name,data)
    collection.objects.link(camera)
    scene.camera=camera
    camera.data.type='ORTHO'
    aim((2.6,-7,3.0))
    floor_data=bpy.data.meshes.new('Hastatus_Studio_Floor')
    floor_data.from_pydata([(-20,-20,0),(20,-20,0),(20,20,0),(-20,20,0)],[],[(0,1,2,3)])
    floor=bpy.data.objects.new('Preview_Floor_Not_Exported',floor_data)
    collection.objects.link(floor)
    floor_mat=bpy.data.materials.new('Hastatus_Studio_Floor_Material')
    floor_mat.use_nodes=True
    bsdf=next(n for n in floor_mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED')
    bsdf.inputs['Base Color'].default_value=(.19,.205,.23,1)
    bsdf.inputs['Roughness'].default_value=.93
    floor_data.materials.append(floor_mat)
    try:
        scene.render.engine='CYCLES'
    except TypeError as error:
        raise RuntimeError('Для студийного рендера нужен Cycles: '+str(error))
    scene.cycles.samples=32
    scene.cycles.use_denoising=True
    scene.render.resolution_x=1200
    scene.render.resolution_y=1700
    scene.render.resolution_percentage=100
    scene.view_settings.view_transform='AgX'
    # Упакованный скетч — только референс, к материалам не подключается.
    refs=bpy.data.collections.get('Hastatus_Reference')
    if refs is None:
        refs=bpy.data.collections.new('Hastatus_Reference')
        scene.collection.children.link(refs)
        image=bpy.data.images.load(str(OUT/'source/reference_hap.jpg'),check_existing=True)
        image.pack()
        ref=bpy.data.objects.new('Reference_hap_front_back',None)
        ref.empty_display_type='IMAGE'
        ref.data=image
        ref.empty_display_size=2.8
        ref.location=(0,1.2,1.35)
        ref.rotation_euler=(math.pi/2,0,0)
        ref.hide_render=True
        refs.objects.link(ref)
    refs.hide_viewport=True
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type=='VIEW_3D':
                space=area.spaces.active
                space.region_3d.view_location=Vector((.15,0,1.25))
                space.region_3d.view_distance=3.7
                space.region_3d.view_rotation=camera.rotation_euler.to_quaternion()
                space.shading.color_type='MATERIAL'
                space.clip_end=200
    status('studio_ready')

def aim(location,target=(.17,0,1.33),span=2.96):
    camera=bpy.data.scenes[SCENE].camera
    camera.location=location
    camera.rotation_euler=(Vector(target)-camera.location).to_track_quat('-Z','Y').to_euler()
    camera.data.ortho_scale=span

def render(name,location,target=(.17,0,1.33),span=2.96):
    scene=bpy.data.scenes[SCENE]
    aim(location,target,span)
    scene.render.filepath=str(OUT/'previews'/name)
    scene.render.image_settings.file_format='PNG'
    bpy.ops.render.render(write_still=True)

def category(name):
    if name.startswith('Body_'):
        return 'body'
    if name.startswith('Helmet_Horsehair'):
        return 'crest'
    if name.startswith('Helmet_'):
        return 'helmet'
    if name.startswith('Shield_'):
        return 'shield'
    if name.startswith('Spear_'):
        return 'spear'
    if name.startswith('Armor_Greave'):
        return 'greaves'
    if name.startswith(('Garment_','Sandals_')):
        return 'garments'
    return 'cuirass'

def finish():
    scene=bpy.data.scenes[SCENE]
    originals=[o for o in bpy.data.collections[ASSETS].objects if o.type=='MESH']
    for obj in originals:
        assert all(math.isfinite(c) for vertex in obj.data.vertices for c in vertex.co), obj.name
        for mat in obj.data.materials:
            assert mat and not any(n.type=='TEX_IMAGE' for n in mat.node_tree.nodes), obj.name
    shield=bpy.data.objects['Shield_True_Circular_Bowl']
    coordinates=[v.co for v in shield.data.vertices]
    span_x=max(v.x for v in coordinates)-min(v.x for v in coordinates)
    span_z=max(v.z for v in coordinates)-min(v.z for v in coordinates)
    assert abs(span_x-span_z)<1e-5 and abs(span_x-.82)<1e-5
    status('rendering_front')
    render('hastatus_front.png',(2.6,-7,3.0))
    status('rendering_back')
    render('hastatus_back.png',(-2.8,7,2.9))
    render('hastatus_helmet_detail.png',(1.9,-4,2.7),(0,0,1.72),.94)
    render('hastatus_grip_detail.png',(1.7,-4,2.0),(.51,-.02,1.10),.83)
    aim((2.6,-7,3.0))
    bpy.ops.object.select_all(action='DESELECT')
    root=bpy.data.objects['Hastatus_v1']
    root.select_set(True)
    bpy.context.view_layer.objects.active=root
    reference=bpy.data.objects['Reference_hap_front_back'].data
    reference.filepath='//reference_hap.jpg'
    root['textured']=False
    root['rigged']=False
    root['reference']='reference_hap.jpg'
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type=='VIEW_3D':
                area.spaces.active.region_3d.view_location=Vector((.17,0,1.33))
                area.spaces.active.region_3d.view_rotation=scene.camera.rotation_euler.to_quaternion()
                area.spaces.active.region_3d.view_distance=3.8
                area.spaces.active.shading.color_type='MATERIAL'
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'source/hastatus_v1.blend'),
                              copy=True,relative_remap=False,compress=True)
    status('exporting')
    temporary=bpy.data.collections.new('Hastatus_Temporary_Export')
    scene.collection.children.link(temporary)
    export_root=bpy.data.objects.new('hastatus_v1',None)
    temporary.objects.link(export_root)
    groups={}
    depsgraph=bpy.context.evaluated_depsgraph_get()
    source_triangles=0
    for original in originals:
        data=bpy.data.meshes.new_from_object(original.evaluated_get(depsgraph),depsgraph=depsgraph)
        data.validate(clean_customdata=True)
        data.update()
        source_triangles+=sum(len(p.vertices)-2 for p in data.polygons)
        obj=bpy.data.objects.new(original.name+'_export',data)
        temporary.objects.link(obj)
        obj.parent=export_root
        obj.matrix_world=original.matrix_world.copy()
        groups.setdefault(category(original.name),[]).append(obj)
    targets={'body':40000,'crest':16000,'cuirass':18000,'helmet':8000,
             'greaves':6000,'garments':12000,'shield':9000,'spear':2000}
    exported=[]
    for key,objects in sorted(groups.items()):
        obj=join(objects,'hastatus_'+key)
        count=sum(len(p.vertices)-2 for p in obj.data.polygons)
        if count>targets[key]:
            mod=obj.modifiers.new('Export_Simplification','DECIMATE')
            mod.ratio=targets[key]/count
            bpy.ops.object.modifier_apply(modifier=mod.name)
        obj.data.validate(clean_customdata=True)
        obj.data.update()
        exported.append({'part':key,'triangles':sum(len(p.vertices)-2 for p in obj.data.polygons)})
    bpy.ops.object.select_all(action='DESELECT')
    export_root.select_set(True)
    for obj in temporary.objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active=export_root
    bpy.ops.export_scene.gltf(filepath=str(OUT/'models/hastatus_v1.glb'),
                             use_selection=True,use_active_scene=True,export_animations=False,
                             export_cameras=False,export_lights=False)
    for obj in originals:
        obj.hide_render=True
    status('rendering_export')
    render('hastatus_export.png',(2.6,-7,3.0))
    for obj in originals:
        obj.hide_render=False
    for obj in list(temporary.objects):
        data=obj.data
        bpy.data.objects.remove(obj,do_unlink=True)
        if isinstance(data,bpy.types.Mesh) and data.users==0:
            bpy.data.meshes.remove(data)
    bpy.data.collections.remove(temporary)
    vertices=[obj.matrix_world@Vector(corner) for obj in originals for corner in obj.bound_box]
    manifest={'id':'hastatus_v1','reference':'source/reference_hap.jpg','source':'source/hastatus_v1.blend',
              'model':'models/hastatus_v1.glb','prototype':True,'rigged':False,'animations':[],
              'textures':[],'material':'Hastatus_Neutral_Clay','unit_scale_meters':1.0,
              'shield_radius_m':.41,'shield_front_blender':[0,1,0],
              'source_objects':len(originals),'source_triangles':source_triangles,
              'export_parts':exported,'export_triangles':sum(p['triangles'] for p in exported),
              'bounds_blender_z_up':{'min':[min(v[i] for v in vertices) for i in range(3)],
                                     'max':[max(v[i] for v in vertices) for i in range(3)]}}
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    bpy.ops.object.select_all(action='DESELECT')
    root.select_set(True)
    bpy.context.view_layer.objects.active=root
    status('complete',export_triangles=manifest['export_triangles'],parts=len(exported))

def start_finish():
    def job():
        try:
            finish()
        except Exception:
            status('failed',error=traceback.format_exc())
        return None
    status('scheduled')
    bpy.app.timers.register(job,first_interval=1.0)
    print('Рендер и экспорт запущены; состояние в source/job.json')

if __name__=='__main__' and '--all' in sys.argv:
    initialize()
    body()
    armor()
    equipment()
    studio()
    finish()
