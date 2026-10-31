"""Auto ausschneiden, auf App-Konvention drehen/normieren (Länge 1 entlang z, vorne -z, rechts +x,
Boden y=0) und Räder vermessen. Speichert car_norm.npz und Kontrollbilder."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from matplotlib.patches import Circle
from objmesh import load_obj, vertex_colors

obj_path, tex_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
v, vt, vn, faces = load_obj(obj_path)
colors = vertex_colors(v, vt, faces, tex_path)
tri = faces[:, :, 0]

footprint = (np.abs(v[:, 0] - 0.05) < 0.36) & (np.abs(v[:, 2] - 0.08) < 0.22)
keep = (v[tri][:, :, 1].max(1) > 0.022) & footprint[tri].all(1)
car_tri = tri[keep]

# Umindizieren auf die benutzten Vertices
used, inverse = np.unique(car_tri, return_inverse=True)
car_tri = inverse.reshape(-1, 3)
p, uv, n, col = v[used], vt[used], vn[used], colors[used]

# Drehen: vorne war -x -> -z, rechts war -z -> +x  =>  (x, y, z)' = (-z, y, x)
R = np.array([[0, 0, -1], [0, 1, 0], [1, 0, 0]], dtype=float)
# Das Auto stand im Scan leicht schräg: linke Räder lagen ~3,5° versetzt zu den rechten.
yaw = np.radians(float(os.environ.get("CAR_YAW_DEG", "-3.54")))
Ry = np.array([[np.cos(yaw), 0, np.sin(yaw)], [0, 1, 0], [-np.sin(yaw), 0, np.cos(yaw)]])
R = Ry @ R
p = p @ R.T
n = n @ R.T
lo, hi = p.min(0), p.max(0)
center = np.array([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2])
scale = 1.0 / (hi[2] - lo[2])
p = (p - center) * scale
lo, hi = p.min(0), p.max(0)
print("normiert min", lo.round(4), "max", hi.round(4), "Ausdehnung", (hi - lo).round(4))
print("Skalierung", scale, "Original-Länge", 1 / scale)

lum = col @ np.array([0.3, 0.59, 0.11])
sat = col.max(1) - col.min(1)
wheels = {}
for name, sx, sz in [("FL", -1, -1), ("FR", 1, -1), ("RL", -1, 1), ("RR", 1, 1)]:
    side = (p[:, 0] * sx) > (hi[0] * sx if sx > 0 else -lo[0]) * 0.55 if False else (p[:, 0] * sx > 0.18)
    quad = side & (p[:, 2] * sz > 0.05) & (p[:, 1] < 0.36)
    rim = quad & (lum > 0.28) & (lum < 0.75) & (sat < 0.12) & (p[:, 1] < 0.28)
    c = np.median(p[rim], axis=0)
    dark = quad & (lum < 0.2)
    d = np.hypot(p[dark, 2] - c[2], p[dark, 1] - c[1])
    near = dark.copy()
    near[dark] = d < 0.2
    dd = np.hypot(p[near, 2] - c[2], p[near, 1] - c[1])
    r_est = np.percentile(dd, 92)
    outer_x = p[near, 0].max() if sx > 0 else p[near, 0].min()
    wheels[name] = dict(center=c, radius=r_est, outer_x=outer_x, n_rim=int(rim.sum()))
    print(f"Rad {name}: Felgenpunkte {rim.sum():4d}  Mitte x={c[0]:.3f} y={c[1]:.3f} z={c[2]:.3f}  Radius~{r_est:.3f}  außen x={outer_x:.3f}")

np.savez(os.path.join(out_dir, "car_norm.npz"), p=p, uv=uv, n=n, tri=car_tri, col=col)

def render(ax, a, b, depth, near_is_large, flip_a=False):
    pts = p[car_tri]
    d = pts[:, :, depth].mean(1)
    order = np.argsort(d if near_is_large else -d)
    polys = pts[order][:, :, [a, b]].copy()
    if flip_a:
        polys[:, :, 0] *= -1
    ax.add_collection(PolyCollection(polys, facecolors=col[car_tri[order]].mean(1), edgecolors="none"))
    ax.autoscale()
    ax.set_aspect("equal")
    ax.minorticks_on()
    ax.grid(True, which="major", alpha=0.5)
    ax.grid(True, which="minor", alpha=0.15)

fig, axes = plt.subplots(1, 2, figsize=(20, 8), gridspec_kw={"width_ratios": [1.6, 1]})
# Rechte Seite: Kamera bei +x, Blick nach -x; horizontale Achse z (vorne = -z links)
render(axes[0], 2, 1, 0, True)
axes[0].set_title("rechte Seite (Kamera +x), horizontal = z, vorne links")
for name in ("FR", "RR"):
    w = wheels[name]
    axes[0].add_patch(Circle((w["center"][2], w["center"][1]), w["radius"], fill=False, color="cyan", lw=1.5))
# Front: Kamera bei -z, Blick nach +z; horizontale Achse x (rechts = +x erscheint links im Bild -> flip)
render(axes[1], 0, 1, 2, False, flip_a=True)
axes[1].set_title("Front (Kamera -z), horizontal = -x")
plt.tight_layout()
plt.savefig(os.path.join(out_dir, "norm_views.png"), dpi=75)

fig, ax = plt.subplots(figsize=(9, 14))
render(ax, 0, 2, 1, True)
ax.set_title("oben, horizontal = x (rechts), vertikal = z (vorne unten)")
plt.savefig(os.path.join(out_dir, "norm_top.png"), dpi=60)
