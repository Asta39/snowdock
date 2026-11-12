"""
Elfy: a tiny 3D elf with a snow shovel, modelled, animated and rendered in Blender.

Builds the character from primitives (no external assets), animates it with
keyframes (push-shovel walk cycle, wave goodbye), and renders each frame
side-on with a transparent background into a sprite sheet for SnowDock.

  /Applications/Blender.app/Contents/MacOS/Blender -b -P blender/make_elfy.py -- \
      --out Resources/elfy --size 128

Output: Resources/elfy/elfy_sheet.png (8 columns x 4 rows of SIZE px frames)
  frames  0-11 : push  (walking right, shovel blade on the ground)
  frames 12-27 : wave  (shovel planted, waving goodbye)
Also saves blender/elfy.blend for hand editing.
"""
import bpy
import math
import os
import sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default, cast=str):
    return cast(argv[argv.index(name) + 1]) if name in argv else default

OUT = os.path.abspath(arg("--out", "Resources/elfy"))
SIZE = arg("--size", 128, int)
os.makedirs(OUT, exist_ok=True)
FRAMES_DIR = os.path.join(OUT, "_frames")
os.makedirs(FRAMES_DIR, exist_ok=True)
BLEND = os.path.join(os.path.dirname(os.path.abspath(__file__)), "elfy.blend")

PUSH_FRAMES = 12
WAVE_FRAMES = 16

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
D = bpy.data

# ---------------------------------------------------------------- materials
def mat(name, rgb, rough=0.6, sheen=0.0, emit=0.0):
    m = D.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Roughness"].default_value = rough
    if sheen and "Sheen Weight" in b.inputs:
        b.inputs["Sheen Weight"].default_value = sheen
    if emit and "Emission Strength" in b.inputs:
        b.inputs["Emission Color"].default_value = (*rgb, 1)
        b.inputs["Emission Strength"].default_value = emit
    return m

M = {
    "skin":   mat("skin",   (0.95, 0.72, 0.58), 0.5),
    "cheek":  mat("cheek",  (0.95, 0.45, 0.45), 0.5),
    "green":  mat("green",  (0.10, 0.50, 0.22), 0.7, sheen=0.4),
    "dkgreen":mat("dkgreen",(0.05, 0.30, 0.13), 0.7),
    "red":    mat("red",    (0.80, 0.08, 0.10), 0.6, sheen=0.3),
    "white":  mat("white",  (0.97, 0.97, 0.97), 0.9, sheen=0.6),
    "belt":   mat("belt",   (0.10, 0.06, 0.04), 0.4),
    "gold":   mat("gold",   (0.95, 0.75, 0.20), 0.25),
    "boot":   mat("boot",   (0.25, 0.12, 0.06), 0.5),
    "wood":   mat("wood",   (0.55, 0.35, 0.18), 0.6),
    "metal":  mat("metal",  (0.55, 0.62, 0.70), 0.3),
    "eye":    mat("eye",    (0.03, 0.03, 0.05), 0.2),
}

# ---------------------------------------------------------------- helpers
def obj_from(op, name, material, parent=None, **kw):
    op(**kw)
    o = bpy.context.active_object
    o.name = name
    o.data.materials.append(material)
    for p in o.data.polygons:
        p.use_smooth = True
    if parent:
        o.parent = parent
        o.matrix_parent_inverse = parent.matrix_world.inverted()
    return o

def empty(name, loc, parent=None):
    e = D.objects.new(name, None)
    scene.collection.objects.link(e)
    e.location = loc                         # world position
    if parent:
        reparent(e, parent)                  # keep world position (pivot stays at the joint)
    return e

def sphere(name, m, loc, scale, parent=None, seg=24):
    o = obj_from(bpy.ops.mesh.primitive_uv_sphere_add, name, m, None, segments=seg, ring_count=seg // 2, radius=1, location=loc)
    o.scale = scale
    if parent: reparent(o, parent)
    return o

def cyl(name, m, loc, r, depth, rot=(0, 0, 0), parent=None, r2=None):
    if r2 is None:
        o = obj_from(bpy.ops.mesh.primitive_cylinder_add, name, m, None, vertices=20, radius=r, depth=depth, location=loc, rotation=rot)
    else:
        o = obj_from(bpy.ops.mesh.primitive_cone_add, name, m, None, vertices=20, radius1=r, radius2=r2, depth=depth, location=loc, rotation=rot)
    if parent: reparent(o, parent)
    return o

def reparent(o, parent):
    bpy.context.view_layer.update()          # make matrix_world reflect scale/rotation just set
    mw = o.matrix_world.copy()
    o.parent = parent
    o.matrix_world = mw

# ---------------------------------------------------------------- build Elfy (faces +X; Z up; ~2.2 units tall)
root = empty("Elfy", (0, 0, 0))
hips = empty("hips", (0, 0, 0.78), root)

# legs (pivot at hip) with curly boots
legs = {}
for side, y in (("L", 0.13), ("R", -0.13)):
    pivot = empty(f"leg_{side}", (0, y, 0.78), root)
    cyl(f"thigh_{side}", M["red" if side == "L" else "white"], (0, y, 0.48), 0.085, 0.6, parent=pivot)  # striped tights
    cyl(f"stripe_{side}", M["white" if side == "L" else "red"], (0, y, 0.38), 0.088, 0.12, parent=pivot)
    boot = sphere(f"boot_{side}", M["boot"], (0.06, y, 0.1), (0.2, 0.1, 0.09), pivot)
    cyl(f"toe_{side}", M["boot"], (0.25, y, 0.18), 0.04, 0.16, rot=(0, math.radians(-50), 0), parent=pivot, r2=0.01)
    sphere(f"toeball_{side}", M["gold"], (0.3, y, 0.25), (0.035, 0.035, 0.035), pivot, seg=12)
    legs[side] = pivot

# body: tunic with jagged hem, belt + buckle
body = cyl("tunic", M["green"], (0, 0, 1.05), 0.34, 0.62, parent=hips, r2=0.22)
hem = cyl("hem", M["dkgreen"], (0, 0, 0.76), 0.37, 0.08, parent=hips, r2=0.35)
cyl("belt", M["belt"], (0, 0, 0.98), 0.315, 0.08, parent=hips)
buckle = obj_from(bpy.ops.mesh.primitive_cube_add, "buckle", M["gold"], None, size=1, location=(0.31, 0, 0.98))
buckle.scale = (0.03, 0.11, 0.09); reparent(buckle, hips)
cyl("collar", M["white"], (0, 0, 1.36), 0.24, 0.07, parent=hips)

# head
neck = empty("neck", (0, 0, 1.38), hips)
head = sphere("head", M["skin"], (0.02, 0, 1.6), (0.27, 0.25, 0.26), neck)
sphere("nose", M["skin"], (0.29, 0, 1.58), (0.06, 0.055, 0.055), neck, seg=12)
for y in (0.1, -0.1):
    sphere(f"eye_{y}", M["eye"], (0.255, y, 1.66), (0.03, 0.03, 0.04), neck, seg=12)
    sphere(f"cheek_{y}", M["cheek"], (0.22, y * 1.5, 1.54), (0.05, 0.03, 0.04), neck, seg=12)
# pointy ears
for side, y in (("L", 0.25), ("R", -0.25)):
    e = cyl(f"ear_{side}", M["skin"], (0, y * 1.15, 1.64), 0.07, 0.24,
            rot=(math.radians(90 if side == "L" else -90) + math.radians(-20 if side == "L" else 20), 0, 0), parent=neck, r2=0.0)
# hat: cone with white trim + bobble, bent back
cyl("hat_trim", M["white"], (0, 0, 1.8), 0.27, 0.09, parent=neck)
hat = cyl("hat", M["red"], (-0.08, 0, 2.08), 0.25, 0.55, rot=(0, math.radians(-25), 0), parent=neck, r2=0.02)
sphere("bobble", M["white"], (-0.22, 0, 2.33), (0.07, 0.07, 0.07), neck, seg=16)

# arms (pivot at shoulder) + mittens
arms = {}
for side, y in (("L", 0.32), ("R", -0.32)):
    pivot = empty(f"arm_{side}", (0, y, 1.3), hips)
    cyl(f"sleeve_{side}", M["green"], (0, y, 1.08), 0.07, 0.42, parent=pivot)
    cyl(f"cuff_{side}", M["white"], (0, y, 0.88), 0.08, 0.06, parent=pivot)
    sphere(f"mitten_{side}", M["red"], (0, y, 0.82), (0.075, 0.07, 0.08), pivot, seg=14)
    arms[side] = pivot

# shovel (own pivot so it can be pushed / planted)
shovel = empty("shovel", (0.36, 0, 1.04), root)
# handle runs from the hands (0.24, 0.86) down to the blade (0.78, 0.14)
h0, h1 = Vector((0.36, 0, 1.04)), Vector((0.8, 0, 0.16))
hd = h1 - h0
cyl("handle", M["wood"], tuple((h0 + h1) / 2), 0.025, hd.length,
    rot=(0, math.atan2(hd.x, hd.z), 0), parent=shovel)
cyl("grip", M["red"], tuple(h0 - hd.normalized() * 0.04), 0.04, 0.16, rot=(math.radians(90), 0, 0), parent=shovel)
blade = obj_from(bpy.ops.mesh.primitive_cube_add, "blade", M["metal"], None, size=1, location=(0.8, 0, 0.13))
blade.scale = (0.04, 0.36, 0.24); blade.rotation_euler = (0, math.radians(-20), 0); reparent(blade, shovel)
# a little scoop of snow on the blade
sphere("scoop", M["white"], (0.9, 0, 0.1), (0.1, 0.22, 0.09), shovel, seg=14)

# ---------------------------------------------------------------- animation
def key(o, frame, rot=None, loc=None):
    if rot is not None:
        o.rotation_euler = rot; o.keyframe_insert("rotation_euler", frame=frame)
    if loc is not None:
        o.location = loc; o.keyframe_insert("location", frame=frame)

def push_pose(t):
    """t in [0,1): walk cycle leaning into the shovel."""
    a = math.sin(t * 2 * math.pi)
    b = abs(math.sin(t * 2 * math.pi))
    lean = math.radians(14)
    return {
        "hips": ((0, lean, 0), (0, 0, 0.78 + 0.03 * b)),
        "leg_L": ((0, math.radians(28) * a, 0), None),
        "leg_R": ((0, -math.radians(28) * a, 0), None),
        "arm_L": ((0, math.radians(-62) + math.radians(6) * a, 0), None),   # both arms forward on the handle
        "arm_R": ((0, math.radians(-55) - math.radians(6) * a, 0), None),
        "neck": ((0, math.radians(-8), 0), None),
        "shovel": ((0, math.radians(2) * a, 0), (0.36 + 0.03 * b, 0, 1.04 + 0.02 * b)),
    }

def wave_pose(t):
    """t in [0,1): standing tall, shovel planted, right arm waving."""
    w = math.sin(t * 2 * math.pi * 2)       # two waves per loop
    return {
        "hips": ((0, 0, 0), (0, 0, 0.78)),
        "leg_L": ((0, 0, 0), None),
        "leg_R": ((0, 0, 0), None),
        "arm_L": ((math.radians(10), math.radians(-12), 0), None),   # resting on the planted shovel
        "arm_R": ((math.radians(-150) + math.radians(25) * w, 0, 0), None),  # raised, waving
        "neck": ((math.radians(6) * w, 0, math.radians(25)), None),         # turns toward viewer
        "shovel": ((0, math.radians(26), 0), (0.14, 0.42, 1.02)),         # planted upright at his side
    }

OBJ = {"hips": hips, "leg_L": legs["L"], "leg_R": legs["R"], "arm_L": arms["L"], "arm_R": arms["R"], "neck": neck, "shovel": shovel}
frame = 1
for i in range(PUSH_FRAMES):
    for n, (r, l) in push_pose(i / PUSH_FRAMES).items(): key(OBJ[n], frame, r, l)
    frame += 1
for i in range(WAVE_FRAMES):
    for n, (r, l) in wave_pose(i / WAVE_FRAMES).items(): key(OBJ[n], frame, r, l)
    frame += 1
scene.frame_start, scene.frame_end = 1, frame - 1
for o in OBJ.values():
    if o.animation_data and o.animation_data.action:
        for fc in getattr(o.animation_data.action, "fcurves", []):
            for kp in fc.keyframe_points:
                kp.interpolation = "LINEAR"

# turn him a little toward the camera so he reads as 3D
root.rotation_euler = (0, 0, math.radians(-28))

# ---------------------------------------------------------------- camera, light, render
cam = D.objects.new("cam", D.cameras.new("cam"))
cam.data.type = "ORTHO"; cam.data.ortho_scale = 3.0
cam.location = (0.25, -8, 1.25); cam.rotation_euler = (math.radians(90), 0, 0)
scene.collection.objects.link(cam); scene.camera = cam

sun = D.objects.new("sun", D.lights.new("sun", "SUN"))
sun.data.energy = 3.5; sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(-30))
fill = D.objects.new("fill", D.lights.new("fill", "AREA"))
fill.data.energy = 300; fill.data.size = 4; fill.data.color = (0.7, 0.8, 1.0)
fill.location = (-3, -4, 3); fill.rotation_euler = (math.radians(60), 0, math.radians(-40))
for l in (sun, fill): scene.collection.objects.link(l)
world = D.worlds.new("w"); scene.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.55, 0.65, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.8

r = scene.render
for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
    try:
        r.engine = eng; break
    except TypeError:
        pass
r.film_transparent = True
r.resolution_x = r.resolution_y = SIZE
r.image_settings.file_format = "PNG"; r.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "Standard"

total = scene.frame_end
for f in range(1, total + 1):
    scene.frame_set(f)
    r.filepath = os.path.join(FRAMES_DIR, f"f_{f - 1:02d}.png")
    bpy.ops.render.render(write_still=True)
print("rendered", total, "frames")

# ---------------------------------------------------------------- pack sprite sheet (8 x 4)
COLS, ROWS = 8, 4
sheet = D.images.new("elfy_sheet", COLS * SIZE, ROWS * SIZE, alpha=True)
px = [0.0] * (COLS * SIZE * ROWS * SIZE * 4)
for i in range(total):
    im = D.images.load(os.path.join(FRAMES_DIR, f"f_{i:02d}.png"))
    src = list(im.pixels)
    col, row = i % COLS, i // COLS
    ox, oy = col * SIZE, (ROWS - 1 - row) * SIZE      # Blender images are bottom-up
    for y in range(SIZE):
        s0 = y * SIZE * 4
        d0 = ((oy + y) * COLS * SIZE + ox) * 4
        px[d0:d0 + SIZE * 4] = src[s0:s0 + SIZE * 4]
sheet.pixels = px
sheet.filepath_raw = os.path.join(OUT, "elfy_sheet.png")
sheet.file_format = "PNG"
sheet.save()
print("sheet", sheet.filepath_raw)
bpy.ops.wm.save_as_mainfile(filepath=BLEND)
