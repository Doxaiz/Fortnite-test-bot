#!/usr/bin/env python3
"""Find figure candidates in saved Fortnite frames with a local ONNX model.

Offline diagnostics only: no capture, network, AHK state, or game controls.
Supports the one-class 640x640 YOLO export from the earlier FORMA install.
Optional context hints are visual clues, not friend/foe identification.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time


MAX_PIXELS = 16_000_000
MAX_IMAGE_BYTES = 128 * 1024 * 1024
MAX_MODEL_BYTES = 128 * 1024 * 1024
MODEL_PATH = Path(__file__).resolve().parents[1] / "forma_model" / "runtime-v1" / "fortnite.onnx"
# Pins from the previous FORMA installation, not certificates of safety or quality.
LEGACY_HASHES = frozenset({
    "0ace6e595b3d5ba59bf12e1e0160d11094d712a17c97c2e95f2b9b7a88a2e2ee",
    "111de5603933ffcab0a9a0f472e9e02d341545fb6a2dea54c403b11385c8942f",
})


def read_limited(path: Path, limit: int) -> bytes:
    with path.open("rb") as source:
        data = source.read(limit + 1)
    if not 0 < len(data) <= limit:
        raise ValueError(f"Пустой или слишком большой файл: {path.name}")
    return data


def verified_model(path: Path, expected: str | None) -> bytes:
    if path.suffix.lower() != ".onnx":
        raise ValueError("Нужен локальный файл .onnx; .pt и другие форматы не читаются")
    if expected is not None and not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise ValueError("SHA-256 должен содержать ровно 64 шестнадцатеричных знака")
    data = read_limited(path, MAX_MODEL_BYTES)
    allowed = (expected.lower(),) if expected is not None else LEGACY_HASHES
    if hashlib.sha256(data).hexdigest() not in allowed:
        raise ValueError("SHA-256 модели не совпал. Для своей доверенной ONNX укажите её ожидаемый --sha256")
    return data


def load_cv():
    # Set the limits before importing OpenCV and opening image files.
    os.environ["OPENCV_IO_MAX_IMAGE_PIXELS"] = str(MAX_PIXELS)
    os.environ["OPENCV_IO_MAX_IMAGE_WIDTH"] = "8192"
    os.environ["OPENCV_IO_MAX_IMAGE_HEIGHT"] = "8192"
    import cv2
    import numpy as np
    return cv2, np


def read_frame(path: Path, cv, np):
    if path.suffix.lower() not in {".bmp", ".png", ".jpg", ".jpeg"}:
        raise ValueError(f"Нужен BMP, PNG или JPEG: {path.name}")
    encoded = np.frombuffer(read_limited(path, MAX_IMAGE_BYTES), dtype=np.uint8)
    frame = cv.imdecode(encoded, cv.IMREAD_COLOR | cv.IMREAD_IGNORE_ORIENTATION)
    if frame is None or frame.size > MAX_PIXELS * 3 or max(frame.shape[:2]) > 8192:
        raise ValueError(f"Не удалось прочитать кадр или превышен допустимый размер: {path.name}")
    return frame


class RuntimeNetwork:
    """Use the same tensor and box decoding as the OpenCV backend."""

    def __init__(self, model: bytes, runtime):
        options = runtime.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        options.execution_mode = runtime.ExecutionMode.ORT_SEQUENTIAL
        self.session = runtime.InferenceSession(model, sess_options=options, providers=["CPUExecutionProvider"])
        inputs, outputs = self.session.get_inputs(), self.session.get_outputs()
        if (len(inputs) != 1 or inputs[0].type != "tensor(float)" or inputs[0].shape != [1, 3, 640, 640]
                or len(outputs) != 1 or outputs[0].type != "tensor(float)" or outputs[0].shape != [1, 5, 8400]):
            raise ValueError("Нужен одноклассовый YOLO float32: вход (1,3,640,640), выход (1,5,8400)")
        self.input_name, self.output_name = inputs[0].name, outputs[0].name

    def setInput(self, tensor):
        self.tensor = tensor

    def forward(self):
        return self.session.run([self.output_name], {self.input_name: self.tensor})[0]


def load_network(model: bytes, backend: str, cv, np):
    # Both engines parse the already verified bytes, not a second read of the path.
    if backend == "onnxruntime":
        try:
            import onnxruntime
        except ImportError as exc:
            raise ValueError("Для --backend onnxruntime нужен пакет onnxruntime; см. docs/enemy-vision.md") from exc
        return RuntimeNetwork(model, onnxruntime)
    return cv.dnn.readNetFromONNX(np.frombuffer(model, dtype=np.uint8))


def detect_figures(net, frame, cv, np, confidence: float = 0.25) -> list[dict]:
    height, width = frame.shape[:2]
    scale = min(640 / width, 640 / height)
    resized_w, resized_h = max(1, round(width * scale)), max(1, round(height * scale))
    pad_x, pad_y = (640 - resized_w) // 2, (640 - resized_h) // 2
    canvas = np.full((640, 640, 3), 114, dtype=np.uint8)
    canvas[pad_y:pad_y + resized_h, pad_x:pad_x + resized_w] = cv.resize(frame, (resized_w, resized_h))
    net.setInput(cv.dnn.blobFromImage(canvas, 1 / 255, (640, 640), swapRB=True))
    pred = net.forward()
    if pred.shape != (1, 5, 8400):
        raise ValueError(f"Не поддерживается выход модели {pred.shape}: нужен одноклассовый YOLO (1,5,8400)")
    sx, sy = resized_w / width, resized_h / height
    rows = pred[0].T
    keep = np.isfinite(rows).all(axis=1) & (rows[:, 4] >= confidence) & (rows[:, 4] <= 1)
    keep &= (rows[:, 2] > 0) & (rows[:, 3] > 0)
    boxes, scores = [], []
    for cx, cy, bw, bh, score in rows[keep].astype(np.float64):
        x1 = max(0, min(width, round((cx - bw / 2 - pad_x) / sx)))
        x2 = max(0, min(width, round((cx + bw / 2 - pad_x) / sx)))
        y1 = max(0, min(height, round((cy - bh / 2 - pad_y) / sy)))
        y2 = max(0, min(height, round((cy + bh / 2 - pad_y) / sy)))
        if x2 > x1 and y2 > y1:
            boxes.append([x1, y1, x2 - x1, y2 - y1])
            scores.append(float(score))
    if not boxes:
        return []
    indices = cv.dnn.NMSBoxes(boxes, scores, max(0.0, confidence - 1e-7), 0.45)
    picked = sorted(np.asarray(indices).reshape(-1), key=lambda i: (-scores[i], i))[:32]
    return [dict(zip(("x", "y", "w", "h", "score"), (*boxes[i], round(scores[i], 5)))) for i in picked]


def marker_above(frame, box: dict, cv, np) -> dict | None:
    """A white downward marker and a cyan name above the same figure, not a team classifier."""
    height, width = frame.shape[:2]
    x, y, w, h = (box[k] for k in ("x", "y", "w", "h"))
    pad = min(round(width * 0.04), max(10, round(w * 0.60)))
    rise = min(round(height * 0.12), max(24, round(h * 0.90)))
    left, right = max(0, x - pad), min(width, x + w + pad)
    top, bottom = max(0, y - rise), y - 1
    if (right - left < 5 or bottom - top < 6):
        return None
    roi = frame[top:bottom, left:right]
    b, g, r = np.moveaxis(roi.astype(np.int16), -1, 0)
    cyan = (b >= 145) & (g >= 145) & (g >= r + 30) & (b >= r + 34)
    if np.count_nonzero(cyan) < 6:
        return None
    lo, hi = roi.min(axis=2), roi.max(axis=2)
    white = (lo >= 203) & (hi - lo <= 34)
    _, labels, stats, _ = cv.connectedComponentsWithStats(white.astype(np.uint8), connectivity=8)
    for label, stat in enumerate(stats[1:], 1):
        mx, my, mw, mh, area = map(int, stat)
        if (mw < 5 or mh < 3 or not 1.2 * mh <= mw <= 3.6 * mh
                or mw > min(width * 0.075, max(12, w * 1.4)) or area < mw * mh * 0.24):
            continue
        if abs(left + mx + mw / 2 - (x + w / 2)) > max(w * 0.4, mw * 0.6):
            continue
        if y - (top + my + mh) > max(12, h * 0.58):
            continue
        component = labels[my:my + mh, mx:mx + mw] == label
        # The upper part of a downward marker is wider than the lower one.
        band = max(1, mh // 3)
        upper = component[:band].sum(axis=1).max()
        lower = component[-band:].sum(axis=1).max()
        if upper < 3 or lower > upper * 0.67:
            continue
        # A cyan rim touching the white region can be part of the same hit
        # indicator (e.g. a shield arc in a scope). Require a separate band.
        name_top = max(0, my - 2 * mh)
        gap = max(1, round(mh / 8))
        if my - name_top <= gap:
            continue
        seam = cyan[my - gap:my, mx:mx + mw]
        if np.count_nonzero(seam, axis=1).max() >= max(2, mw // 12):
            continue
        name = cyan[name_top:my - gap, max(0, mx - mw):mx + 2 * mw]
        if np.count_nonzero(name) >= max(6, mh) and np.count_nonzero(name.any(axis=0)) >= max(4, mw // 4):
            return {"x": left + mx, "y": top + my, "w": mw, "h": mh}
    return None


def add_view_hints(frame, boxes: list[dict], view: str, cv, np) -> list[dict]:
    """Keep box order, positions, and scores. Neither a hint nor its absence confirms hostility."""
    height, width = frame.shape[:2]
    annotated = []
    for box in boxes:
        hint, marker = "unclassified", None
        if view == "interface":
            hint = "interface-view"
        elif (marker := marker_above(frame, box, cv, np)) is not None:
            hint = "ally-marker"
        elif view == "third-person":
            x, y, w, h = (box[k] for k in ("x", "y", "w", "h"))
            if (0.28 * width <= x + w / 2 <= 0.58 * width and y + h >= 0.67 * height
                    and w >= 0.06 * width and h >= 0.26 * height):
                hint = "own-area"
        item = {**box, "hint": hint}
        if marker is not None:
            item["marker"] = marker
        annotated.append(item)
    return annotated


def write_preview(path: Path, frame, boxes: list[dict], cv) -> None:
    annotated = frame.copy()
    hints = {
        "ally-marker": ("ally marker?", (30, 215, 255)),
        "own-area": ("own area?", (205, 205, 205)),
        "interface-view": ("interface", (205, 205, 205)),
        "unclassified": ("figure?", (255, 200, 40)),
    }
    for box in boxes:
        x, y, w, h = (box[key] for key in ("x", "y", "w", "h"))
        name, color = hints.get(box.get("hint"), ("figure", (255, 200, 40)))
        cv.rectangle(annotated, (x, y), (x + w - 1, y + h - 1), color, 2)
        if "marker" in box:
            mx, my, mw, mh = (box["marker"][key] for key in ("x", "y", "w", "h"))
            cv.rectangle(annotated, (mx, my), (mx + mw - 1, my + mh - 1), color, 1)
        cv.putText(annotated, f"{name} {box['score']:.2f}", (x, max(14, y - 4)),
                   cv.FONT_HERSHEY_SIMPLEX, 0.5, color, 1, cv.LINE_AA)
    ok, png = cv.imencode(".png", annotated)
    if not ok:
        raise ValueError("Не удалось создать PNG")
    # Never overwrite an original or a previous result.
    with path.open("xb") as output:
        output.write(png.tobytes())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frames", metavar="FRAME", type=Path, nargs="+", help="сохранённые BMP / PNG / JPEG")
    parser.add_argument("--model", type=Path, default=MODEL_PATH, help="локальная проверенная ONNX")
    parser.add_argument("--sha256", help="ожидаемый SHA-256 своей доверенной ONNX")
    parser.add_argument("--backend", choices=("opencv", "onnxruntime"), default="opencv",
                        help="локальный CPU-бэкенд; по умолчанию OpenCV")
    parser.add_argument("--view", choices=("unknown", "third-person", "scope", "interface"),
                        help="контекст для подсказок на рамке, не меняет детекцию")
    parser.add_argument("--out", type=Path, help="папка для новых PNG с рамками; оригиналы не меняются")
    args = parser.parse_args(argv)
    try:
        if len(args.frames) > 32:
            raise ValueError("Не больше 32 кадров за один запуск")
        model = verified_model(args.model, args.sha256)
        cv, np = load_cv()
        cv.setNumThreads(2)
        net = load_network(model, args.backend, cv, np)
        if args.out:
            args.out.mkdir(parents=True, exist_ok=True)
        for source in args.frames:
            frame = read_frame(source, cv, np)
            start = time.perf_counter()
            boxes = detect_figures(net, frame, cv, np)
            if args.view:
                boxes = add_view_hints(frame, boxes, args.view, cv, np)
            result = {"frame": source.name, "size": [frame.shape[1], frame.shape[0]],
                      "scan_ms": round((time.perf_counter() - start) * 1000, 1), "figure_candidates": boxes}
            if args.view:
                result["view"] = args.view
            if args.backend != "opencv":
                result["backend"] = args.backend
            if args.out:
                preview = args.out / (source.stem + "-figures.png")
                write_preview(preview, frame, boxes, cv)
                result["preview"] = preview.name
            print(json.dumps(result, ensure_ascii=True), flush=True)
        return 0
    except ImportError:
        print("Не установлены NumPy и OpenCV. См. docs/enemy-vision.md", file=sys.stderr)
    except Exception as exc:
        print(f"Проверка не выполнена: {exc}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
