"""
Procedural snowflake generator for SnowDock.

Builds six-fold ice crystals (dendrites, sectored plates, stellar plates, columns-in-plate)
as real 3D meshes, shades them as icy translucent material, and renders each one
top-down with a transparent background.

Run headless:
  /Applications/Blender.app/Contents/MacOS/Blender -b -P blender/make_flakes.py -- \
      --out Resources/flakes --count 8 --size 256 --samples 64

Also writes blender/flakes.blend so the models can be opened and tweaked by hand.
"""
import bpy
import bmesh
import math
import os
import random
import sys
from mathutils import Vector, Matrix

# ---------------------------------------------------------------- args
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default, cast=str):
    return cast(argv[argv.index(name) + 1]) if name in argv else default

OUT = os.path.abspath(arg("--out", "Resources/flakes"))
COUNT = arg("--count", 8, int)
SIZE = arg("--size", 256, int)
SAMPLES = arg("--samples", 64, int)
SAVE_BLEND = os.path.join(os.path.dirname(os.path.abspath(__file__)), "flakes.blend")
os.makedirs(OUT, exist_ok=True)

# ---------------------------------------------------------------- scene reset
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------------------------------------------------------------- geometry helpers
THICK = 0.035  # crystal thickness (flakes are thin plates)

def add_bar(bm, a, b, width, thick=THICK, taper=1.0):
    """Hexagonal-ish prism bar from 2D point a to b (z = 0 plane), tapered toward b."""
    a, b = Vector((a[0], a[1], 0)), Vector((b[0], b[1], 0))
    d = b - a
    if d.length < 1e-5:
        return
    n = Vector((-d.y, d.x, 0)).normalized()
    wa, wb = width / 2, width / 2 * taper
    t = thick / 2
    # 6 verts per end: diamond-ish cross section (ridge on top & bottom, like real crystals)
    def ring(p, w):
        return [p + n * w + Vector((0, 0, 0)),
                p + Vector((0, 0, t)),
                p - n * w,
                p - Vector((0, 0, t))]
    ra = [bm.verts.new(v) for v in ring(a, wa)]
    rb = [bm.verts.new(v) for v in ring(b + d.normalized() * wb * 0.6, wb * 0.15)]  # pointed tip
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((ra[i], ra[j], rb[j], rb[i]))
    bm.faces.new(list(reversed(ra)))
    bm.faces.new(rb)

def add_hex_plate(bm, radius, thick=THICK * 0.8, rot=0.0, z=0.0):
    top, bot = [], []
    for k in range(6):
        ang = rot + k * math.pi / 3
        p = Vector((radius * math.cos(ang), radius * math.sin(ang), 0))
        top.append(bm.verts.new(p + Vector((0, 0, z + thick / 2))))
        bot.append(bm.verts.new(p + Vector((0, 0, z - thick / 2))))
    bm.faces.new(top)
    bm.faces.new(list(reversed(bot)))
    for k in range(6):
        j = (k + 1) % 6
        bm.faces.new((top[k], bot[k], bot[j], top[j]))

def add_hex_plate_at(bm, center, radius, thick=THICK * 0.8, rot=0.0):
    top, bot = [], []
    for k in range(6):
        a = rot + k * math.pi / 3
        p = center + Vector((radius * math.cos(a), radius * math.sin(a), 0))
        top.append(bm.verts.new(p + Vector((0, 0, thick / 2))))
        bot.append(bm.verts.new(p - Vector((0, 0, thick / 2))))
    bm.faces.new(top); bm.faces.new(list(reversed(bot)))
    for k in range(6):
        j = (k + 1) % 6
        bm.faces.new((top[k], bot[k], bot[j], top[j]))

def rot2(p, ang):
    c, s = math.cos(ang), math.sin(ang)
    return (p[0] * c - p[1] * s, p[0] * s + p[1] * c)

def arm_dendrite(rng, depth=2):
    """Returns list of (a, b, width, taper) bars for one arm pointing +Y, recursive side branches."""
    bars = []
    L = 1.0
    bars.append(((0, 0), (0, L), rng.uniform(0.07, 0.1), 0.35))
    nb = rng.randint(3, 6)
    for i in range(nb):
        t = 0.18 + 0.75 * (i + rng.uniform(-0.2, 0.2)) / nb
        length = (1 - t) * rng.uniform(0.35, 0.65)
        ang = math.radians(60)
        for s in (-1, 1):
            a = (0, t * L)
            b = (s * math.sin(ang) * length, t * L + math.cos(ang) * length)
            bars.append((a, b, rng.uniform(0.04, 0.06), 0.3))
            if depth > 1 and length > 0.25:
                # sub-branches parallel to the main arm (classic fern-like dendrite)
                for k in range(rng.randint(1, 3)):
                    u = rng.uniform(0.3, 0.8)
                    pa = (a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u)
                    sl = length * (1 - u) * 0.5
                    pb = (pa[0], pa[1] + sl)
                    bars.append((pa, pb, 0.03, 0.3))
    return bars

def arm_sectored(rng):
    """Broad sector plate arm with ridges."""
    bars = [((0, 0), (0, 0.9), rng.uniform(0.3, 0.38), 0.25)]
    bars.append(((0, 0.05), (0, 1.0), 0.05, 0.3))   # central ridge sticks out
    for i in range(4):                                # ribs across the sector
        t = 0.2 + i * 0.17
        w = (1 - t) * 0.22
        for sgn in (-1, 1):
            bars.append(((0, t), (sgn * w, t + w * 0.58), 0.025, 0.6))
    return bars

def arm_stellar(rng):
    bars = [((0, 0), (0, 1.0), rng.uniform(0.12, 0.18), 0.5)]
    # plates at the tips
    return bars

def stellar_tips(bm, rng):
    """Small hexagonal plates on each arm tip (stellar plate crystal)."""
    tip = rng.uniform(0.72, 0.85); rad = rng.uniform(0.13, 0.18)
    for k in range(6):
        ang = k * math.pi / 3 + math.pi / 2
        c = Vector((tip * math.cos(ang), tip * math.sin(ang), 0))
        add_hex_plate_at(bm, c, rad, rot=ang)

def build_flake(seed):
    rng = random.Random(seed * 1013 + 7)
    style = ["dendrite", "dendrite", "stellar", "sectored", "dendrite", "plate", "stellar", "dendrite"][seed % 8]
    bm = bmesh.new()
    if style == "dendrite":
        arm = arm_dendrite(rng)
        add_hex_plate(bm, rng.uniform(0.12, 0.2))
    elif style == "sectored":
        arm = arm_sectored(rng)
        add_hex_plate(bm, 0.22)
    elif style == "stellar":
        arm = arm_stellar(rng) + arm_dendrite(rng, depth=1)[1:3]
        add_hex_plate(bm, rng.uniform(0.18, 0.26))
        stellar_tips(bm, rng)
    else:  # plate: big hex plate with inner ring + short ribs
        arm = [((0, 0.08), (0, 0.78), 0.05, 0.6), ((0, 0.5), (0.18, 0.62), 0.03, 0.6), ((0, 0.5), (-0.18, 0.62), 0.03, 0.6)]
        add_hex_plate(bm, 0.82, thick=THICK * 0.6, rot=math.pi / 6)
        for rr in (0.5, 0.48):  # raised ring (two close plates read as a ridge)
            add_hex_plate(bm, rr, thick=THICK * (1.6 if rr == 0.5 else 0.3), rot=math.pi / 6)
    for k in range(6):
        ang = k * math.pi / 3
        for a, b, w, taper in arm:
            add_bar(bm, rot2(a, ang), rot2(b, ang), w, taper=taper)
    me = bpy.data.meshes.new(f"flake_{seed}")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(f"flake_{seed}", me)
    scene.collection.objects.link(ob)
    # union-ish cleanup + bevel so edges catch light
    mod = ob.modifiers.new("weld", "WELD")
    mod.merge_threshold = 0.002
    bev = ob.modifiers.new("bevel", "BEVEL")
    bev.width = 0.006
    bev.segments = 2
    for p in me.polygons:
        p.use_smooth = True
    return ob, style

# ---------------------------------------------------------------- material: ice
def ice_material():
    m = bpy.data.materials.new("Ice")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.88, 0.93, 1.0, 1)
    bsdf.inputs["Roughness"].default_value = 0.06
    bsdf.inputs["IOR"].default_value = 1.31  # water ice
    for name in ("Transmission Weight", "Transmission"):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = 0.85
    for name in ("Subsurface Weight", "Subsurface"):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = 0.25
    for name in ("Coat Weight", "Clearcoat"):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = 0.4
    # faint cool emission keeps flakes readable on dark wallpapers
    for name in ("Emission Color", "Emission"):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = (0.75, 0.85, 1.0, 1)
    if "Emission Strength" in bsdf.inputs:
        bsdf.inputs["Emission Strength"].default_value = 0.15
    return m

ICE = ice_material()

# ---------------------------------------------------------------- lights, camera, render
cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = 2.35
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
cam.location = (0, 0, 5)
scene.camera = cam

key = bpy.data.objects.new("key", bpy.data.lights.new("key", "AREA"))
key.data.energy = 220; key.data.size = 3; key.data.color = (1.0, 0.98, 0.95)
key.location = (2.5, 2.5, 4); key.rotation_euler = (math.radians(35), 0, math.radians(135))
rim = bpy.data.objects.new("rim", bpy.data.lights.new("rim", "AREA"))
rim.data.energy = 160; rim.data.size = 2; rim.data.color = (0.7, 0.82, 1.0)
rim.location = (-3, -2, 1.2); rim.rotation_euler = (math.radians(75), 0, math.radians(-55))
for l in (key, rim):
    scene.collection.objects.link(l)

world = bpy.data.worlds.new("w"); scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.35, 0.42, 0.55, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.35

r = scene.render
r.engine = "CYCLES"
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = "GPU"
except Exception as e:
    print("GPU unavailable, using CPU:", e)
r.film_transparent = True
r.resolution_x = r.resolution_y = SIZE
r.image_settings.file_format = "PNG"
r.image_settings.color_mode = "RGBA"
r.image_settings.color_depth = "8"
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Punchy" if "AgX - Punchy" in [i.identifier for i in scene.view_settings.bl_rna.properties["look"].enum_items] else "None"

# ---------------------------------------------------------------- build + render
flakes = []
for i in range(COUNT):
    ob, style = build_flake(i)
    ob.data.materials.append(ICE)
    # slight tilt so light catches the facets (flakes are rendered spinning in-app anyway)
    ob.rotation_euler = (math.radians(random.Random(i).uniform(14, 26)), math.radians(random.Random(i + 99).uniform(-10, 10)), 0)
    flakes.append((ob, style))

for i, (ob, style) in enumerate(flakes):
    for o, _ in flakes:
        o.hide_render = o is not ob
        o.location.x = 0 if o is ob else 100
    r.filepath = os.path.join(OUT, f"flake_{i}.png")
    bpy.ops.render.render(write_still=True)
    print(f"rendered flake_{i} ({style}) -> {r.filepath}")

# lay them out in a row for hand editing and save
for i, (ob, _) in enumerate(flakes):
    ob.hide_render = False
    ob.location = ((i - (COUNT - 1) / 2) * 2.4, 0, 0)
bpy.ops.wm.save_as_mainfile(filepath=SAVE_BLEND)
print("saved", SAVE_BLEND)
