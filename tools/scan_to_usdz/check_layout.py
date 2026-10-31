"""Bereinigte Karosserie mit den geplanten Teilen (Räder, Wischer, Lichter) überlagert zeichnen."""
import os
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from matplotlib.patches import Circle, Rectangle

d = np.load(os.path.join(sys.argv[1], "car_body.npz"))
p, tri, col = d["p"], d["tri"], d["col"]

R, W = 0.108, 0.10
wheels = [(-0.198, -0.31), (0.198, -0.31), (-0.198, 0.243), (0.198, 0.243)]
wipers = [(-0.14, 0.36, -0.158), (0.01, 0.36, -0.158)]  # x, y, z; Arm 0.13 nach +x
headlights = [(-0.165, 0.26, -0.447), (0.165, 0.26, -0.447)]
ind_front = [(-0.15, 0.333, -0.40), (0.15, 0.333, -0.40)]
ind_rear = [(-0.19, 0.16, 0.432), (0.19, 0.16, 0.432)]

def render(ax, a, b, depth, near_is_large, flip_a=False):
    pts = p[tri]
    dd = pts[:, :, depth].mean(1)
    order = np.argsort(dd if near_is_large else -dd)
    polys = pts[order][:, :, [a, b]].copy()
    if flip_a:
        polys[:, :, 0] *= -1
    ax.add_collection(PolyCollection(polys, facecolors=col[tri[order]].mean(1), edgecolors="none"))
    ax.autoscale()
    ax.set_aspect("equal")
    ax.grid(True, alpha=0.3)

fig, axes = plt.subplots(1, 3, figsize=(24, 8), gridspec_kw={"width_ratios": [1.6, 1, 1]})
render(axes[0], 2, 1, 0, True)
axes[0].set_title("rechte Seite + geplante Räder/Wischer")
for x, z in wheels:
    if x > 0:
        axes[0].add_patch(Circle((z, R), R + 0.01, fill=False, color="cyan", lw=2))
for x, y, z in wipers:
    axes[0].plot([z], [y], "mo")
axes[0].plot([-0.158, -0.158 + 0.13 * np.sin(0.346)], [0.36, 0.36 + 0.13 * np.cos(0.346)], "m-")
for x, y, z in ind_rear:
    axes[0].plot([z], [y], "s", color="orange")
for x, y, z in ind_front:
    axes[0].plot([z], [y], "s", color="orange")
axes[0].plot([headlights[0][2]], [headlights[0][1]], "yo", ms=10)

render(axes[1], 0, 1, 2, False, flip_a=True)
axes[1].set_title("Front (horizontal = -x)")
for x, y, z in headlights:
    axes[1].add_patch(Circle((-x, y), 0.03, fill=False, color="yellow", lw=2))
for x, y, z in ind_front:
    axes[1].add_patch(Rectangle((-x - 0.02, y - 0.005), 0.04, 0.01, color="orange"))
for x, y, z in wipers:
    axes[1].plot([-x, -(x + 0.13)], [y, y], "m-", lw=3)
for x, z in wheels:
    axes[1].add_patch(Rectangle((-x - W / 2, 0), W, 2 * R + 0.02, fill=False, color="cyan", lw=2))

render(axes[2], 0, 1, 2, True)
axes[2].set_title("Heck (horizontal = x)")
for x, y, z in ind_rear:
    axes[2].add_patch(Rectangle((x - 0.0175, y - 0.0125), 0.035, 0.025, color="orange"))
plt.tight_layout()
plt.savefig(os.path.join(sys.argv[1], "layout_check.png"), dpi=70)
