"""Oberflächen an den Stellen für Lichter und Wischer vermessen (normierte Koordinaten)."""
import os
import sys
import numpy as np

d = np.load(os.path.join(sys.argv[1], "car_norm.npz"))
p = d["p"]

def near(a_idx, a, b_idx, b, r=0.015):
    return (np.abs(p[:, a_idx] - a) < r) & (np.abs(p[:, b_idx] - b) < r)

def front_z(x, y):
    m = near(0, x, 1, y)
    return p[m, 2].min() if m.any() else None

def rear_z(x, y):
    m = near(0, x, 1, y)
    return p[m, 2].max() if m.any() else None

def top_y(x, z):
    m = near(0, x, 2, z)
    return p[m, 1].max() if m.any() else None

print("Front-Oberfläche z (x, y):")
for y in (0.20, 0.22, 0.24, 0.26, 0.28):
    print(f"  y={y:.2f}: " + "  ".join(f"x={x:+.2f}:{front_z(x, y):+.3f}" for x in (-0.18, -0.15, -0.1, 0, 0.1, 0.15, 0.18)))
print("Heck-Oberfläche z (x, y):")
for y in (0.15, 0.18, 0.21, 0.24):
    print(f"  y={y:.2f}: " + "  ".join(f"x={x:+.2f}:{rear_z(x, y):+.3f}" for x in (-0.2, -0.17, -0.1, 0.1, 0.17, 0.2)))
print("Haube oben y (x, z):")
for z in (-0.42, -0.38, -0.34, -0.3, -0.26, -0.22):
    print(f"  z={z:+.2f}: " + "  ".join(f"x={x:+.2f}:{top_y(x, z):.3f}" for x in (-0.17, -0.13, 0, 0.13, 0.17)))

# Windschutzscheibe: Ebene z = a + b*y aus den vordersten Punkten im Scheibenbereich
ys, zs = [], []
for y in np.arange(0.33, 0.46, 0.01):
    for x in (-0.1, -0.05, 0, 0.05, 0.1):
        m = near(0, x, 1, y, 0.01) & (p[:, 2] < -0.05) & (p[:, 2] > -0.3)
        if m.any():
            ys.append(y)
            zs.append(p[m, 2].min())
b, a = np.polyfit(ys, zs, 1)
angle = np.degrees(np.arctan(-b))
print(f"Scheibe: z = {a:.3f} + {b:.3f}*y  -> Neigung nach hinten {angle:.1f}°")
for y in (0.31, 0.32, 0.33, 0.34):
    print(f"  Scheibe bei y={y:.2f}: z={a + b * y:.3f}")
