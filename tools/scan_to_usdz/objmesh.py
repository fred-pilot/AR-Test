"""Minimaler OBJ-Lader (ein Material, Dreiecke, v/vt/vn mit gemeinsamen Indizes oder getrennt)."""
import numpy as np
from PIL import Image


def load_obj(path):
    v, vt, vn, faces = [], [], [], []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("v "):
                v.append([float(x) for x in line.split()[1:4]])
            elif line.startswith("vt "):
                vt.append([float(x) for x in line.split()[1:3]])
            elif line.startswith("vn "):
                vn.append([float(x) for x in line.split()[1:4]])
            elif line.startswith("f "):
                parts = line.split()[1:]
                idx = []
                for p in parts:
                    comps = p.split("/")
                    idx.append([int(c) - 1 if c else -1 for c in comps] + [-1] * (3 - len(comps)))
                for i in range(1, len(idx) - 1):
                    faces.append([idx[0], idx[i], idx[i + 1]])
    return np.array(v), np.array(vt), np.array(vn), np.array(faces)  # faces: (F, 3, 3) = [v, vt, vn]


def vertex_colors(v, vt, faces, texture_path):
    tex = np.asarray(Image.open(texture_path).convert("RGB")).astype(np.float32) / 255
    h, w, _ = tex.shape
    colors = np.zeros((len(v), 3))
    uv_of_vertex = np.zeros((len(v), 2))
    uv_of_vertex[faces[:, :, 0].ravel()] = vt[faces[:, :, 1].ravel()]
    px = np.clip((uv_of_vertex[:, 0] * (w - 1)).astype(int), 0, w - 1)
    py = np.clip(((1 - uv_of_vertex[:, 1]) * (h - 1)).astype(int), 0, h - 1)
    colors = tex[py, px]
    return colors
