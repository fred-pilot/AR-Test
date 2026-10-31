"""Gescannte Karosserie aufräumen (Räder und Boden-Schürze raus) und als ToyCar.usdz exportieren.

Die drehenden Räder, Wischer und Lichter setzt die App selbst an die vermessenen Stellen.

Mit einer Länge in Metern als viertem Argument entsteht stattdessen das Trainingsmodell für die
Objekterkennung (Create ML): Die gescannten Räder bleiben drin, nur die Schürze fliegt raus, und das
Modell wird auf echte Größe skaliert. Es liegt im selben Koordinatensystem wie ToyCar.usdz, nur mit
der Länge multipliziert, damit die App ihr Modell ohne Verschiebung aufs erkannte Auto setzen kann."""
import os
import shutil
import sys
import numpy as np
from PIL import Image
from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, UsdUtils, Vt

work_dir, tex_dir, out_usdz = sys.argv[1], sys.argv[2], sys.argv[3]
real_length = float(sys.argv[4]) if len(sys.argv) > 4 else None
training = real_length is not None
d = np.load(os.path.join(work_dir, "car_norm.npz"))
p, uv, n, tri = d["p"], d["uv"], d["n"], d["tri"]

WHEEL_R = 0.108
WHEELS = [(-0.198, -0.31), (0.198, -0.31), (-0.198, 0.243), (0.198, 0.243)]  # (x, z), Mitte y = WHEEL_R

c = p[tri].mean(1)
remove = c[:, 1] < 0.075                                   # Schürze bis zum Boden (Scan-Artefakt)
for wx, wz in WHEELS:
    in_wheel = (np.abs(c[:, 0]) > 0.13) & (np.sign(c[:, 0]) == np.sign(wx)) & \
               (np.hypot(c[:, 2] - wz, c[:, 1] - WHEEL_R) < WHEEL_R + 0.007)
    if training:
        remove &= ~in_wheel                                # Räder behalten, sie gehören zum Aussehen
    else:
        remove |= in_wheel
tri = tri[~remove]
print("Dreiecke entfernt", int(remove.sum()), "übrig", len(tri))

used, inverse = np.unique(tri, return_inverse=True)
tri = inverse.reshape(-1, 3)
p, uv, n = p[used], uv[used], n[used]
if training:
    p = p * real_length
else:
    np.savez(os.path.join(work_dir, "car_body.npz"), p=p, uv=uv, tri=tri, col=d["col"][used])

# Texturen: Farbe in voller Auflösung, Normal- und AO-Map halbiert (spart Grafikspeicher auf dem iPhone)
build = os.path.join(work_dir, "usd_build_training" if training else "usd_build")
shutil.rmtree(build, ignore_errors=True)
os.makedirs(os.path.join(build, "textures"))
textures = {
    "diffuse": ("cb495b7cf48b7c572320f2010099cfd6.jpg", None),
    "normal": ("638702917b5c84ee92f8b9bc022309eb.jpg", 2048),
    "occlusion": ("31b7a8ea34be5e220d6a3d5731a0c56e.jpg", 2048),
}
for key, (src, size) in textures.items():
    img = Image.open(os.path.join(tex_dir, src)).convert("RGB")
    if size:
        img = img.resize((size, size), Image.LANCZOS)
    img.save(os.path.join(build, "textures", f"car_{key}.jpg"), quality=90)

stage_path = os.path.join(build, "ToyCar.usdc")
stage = Usd.Stage.CreateNew(stage_path)
UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
UsdGeom.SetStageMetersPerUnit(stage, 1.0)
root = UsdGeom.Xform.Define(stage, "/ToyCar")
stage.SetDefaultPrim(root.GetPrim())

mesh = UsdGeom.Mesh.Define(stage, "/ToyCar/body")
mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
mesh.CreatePointsAttr(Vt.Vec3fArray.FromNumpy(p.astype(np.float32)))
mesh.CreateFaceVertexCountsAttr(Vt.IntArray([3] * len(tri)))
mesh.CreateFaceVertexIndicesAttr(Vt.IntArray.FromNumpy(tri.astype(np.int32).ravel()))
mesh.CreateNormalsAttr(Vt.Vec3fArray.FromNumpy(n.astype(np.float32)))
mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)
mesh.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(*p.min(0)), Gf.Vec3f(*p.max(0))]))
st = UsdGeom.PrimvarsAPI(mesh).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex)
st.Set(Vt.Vec2fArray.FromNumpy(uv.astype(np.float32)))

material = UsdShade.Material.Define(stage, "/ToyCar/Materials/CarMaterial")
surface = UsdShade.Shader.Define(stage, "/ToyCar/Materials/CarMaterial/Surface")
surface.CreateIdAttr("UsdPreviewSurface")
surface.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.75)
surface.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
material.CreateSurfaceOutput().ConnectToSource(surface.ConnectableAPI(), "surface")

reader = UsdShade.Shader.Define(stage, "/ToyCar/Materials/CarMaterial/STReader")
reader.CreateIdAttr("UsdPrimvarReader_float2")
reader.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("st")

def texture(name, file, color_space):
    shader = UsdShade.Shader.Define(stage, f"/ToyCar/Materials/CarMaterial/{name}")
    shader.CreateIdAttr("UsdUVTexture")
    shader.CreateInput("file", Sdf.ValueTypeNames.Asset).Set(f"textures/{file}")
    shader.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(reader.ConnectableAPI(), "result")
    shader.CreateInput("sourceColorSpace", Sdf.ValueTypeNames.Token).Set(color_space)
    shader.CreateInput("wrapS", Sdf.ValueTypeNames.Token).Set("clamp")
    shader.CreateInput("wrapT", Sdf.ValueTypeNames.Token).Set("clamp")
    return shader

diffuse = texture("DiffuseTexture", "car_diffuse.jpg", "sRGB")
surface.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(
    diffuse.CreateOutput("rgb", Sdf.ValueTypeNames.Float3))

normal = texture("NormalTexture", "car_normal.jpg", "raw")
normal.CreateInput("scale", Sdf.ValueTypeNames.Float4).Set(Gf.Vec4f(2, 2, 2, 1))
normal.CreateInput("bias", Sdf.ValueTypeNames.Float4).Set(Gf.Vec4f(-1, -1, -1, 0))
surface.CreateInput("normal", Sdf.ValueTypeNames.Normal3f).ConnectToSource(
    normal.CreateOutput("rgb", Sdf.ValueTypeNames.Float3))

occlusion = texture("OcclusionTexture", "car_occlusion.jpg", "raw")
surface.CreateInput("occlusion", Sdf.ValueTypeNames.Float).ConnectToSource(
    occlusion.CreateOutput("r", Sdf.ValueTypeNames.Float))

UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material)
stage.GetRootLayer().Save()

if os.path.exists(out_usdz):
    os.remove(out_usdz)
ok = UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(stage_path), out_usdz)
print("USDZ", "ok" if ok else "FEHLER", out_usdz, f"{os.path.getsize(out_usdz) / 1e6:.1f} MB" if ok else "")
print("Ausdehnung", p.min(0).round(3), p.max(0).round(3))
