"""공 크기 측정 실험 분석. 촬영 방법은 docs/ball-size-experiment.md

실행:
    python ball_size.py ../data/raw/ball-size
    python ball_size.py ../data/raw/ball-size --roi 20261020-101500-3m=900,500,120,120

앱이 저장한 영상(.mov)과 정보 파일(.json)을 읽는다. 메모에 거리가 있으면(예: 3m, 250cm, 5m-edge)
멈춘 공 영상으로, throw가 있으면 던진 공 영상으로 본다.

공 지름은 두 가지로 잰다.
- d_minor: 밝기로 가중한 공 영역의 2차 모멘트 중 짧은 축. 균일한 원판이면 지름 = 4·√(짧은 축 분산)이다.
  움직임 번짐은 진행 방향(긴 축)만 늘리므로, 짧은 축은 번져도 그대로다.
- d_area: 밝기 가중 면적을 원 넓이로 본 지름. 멈춘 공에서 d_minor와 비교하는 용도다.

멈춘 공 영상들로 "잰 지름 = 기울기 × (1/거리) + 절편"을 맞춘다.
절편이 측정 치우침(px)이다. 카메라 1대 복원 실험에서 치우침 1px이 통과 지점 상하 오차 약 22cm를 만들었다.
"""

import argparse
import csv
import json
import re
from pathlib import Path

import numpy as np

from camera import BALL_DIAMETER

NOMINAL_WIDTH = 1920  # 1080p 영상 가로 px


def parse_distance(memo):
    """메모에서 렌즈-공 거리(m)를 읽는다. '3m', '2.5m', '250cm', '5m-edge' → 3.0, 2.5, 2.5, 5.0. 없으면 None."""
    match = re.search(r"(\d+(?:\.\d+)?)\s*(cm|m)(?![a-z])", memo or "", re.IGNORECASE)
    if not match:
        return None
    value = float(match.group(1))
    return value / 100 if match.group(2).lower() == "cm" else value


def focal_from_fov(fov_deg, width=NOMINAL_WIDTH):
    """가로 화각(도)에서 초점거리(px)."""
    return (width / 2) / np.tan(np.radians(fov_deg) / 2)


def measure(patch, background):
    """공이 들어 있는 작은 조각에서 중심과 지름(px)을 잰다.

    좌표는 픽셀 중심이 정수인 기준이다(왼쪽 위 픽셀의 중심이 (0, 0)).
    patch: 2차원 밝기 배열. background: 공이 없을 때의 같은 위치 밝기(스칼라 또는 같은 크기 배열).
    공이 배경보다 밝거나 어두운 경우 모두 처리한다(차이의 절댓값을 쓴다).
    """
    diff = np.abs(np.asarray(patch, float) - background)
    peak = np.percentile(diff, 99.5)
    if peak <= 0:
        return None
    # 공 영역: 밝기 차이가 최대의 25%를 넘는 곳을 2px 넓힌 범위. 배경 잡음이 분산을 부풀리지 않게 한다.
    core = diff > 0.25 * peak
    mask = core.copy()
    for _ in range(2):
        mask[1:, :] |= mask[:-1, :]
        mask[:-1, :] |= mask[1:, :]
        mask[:, 1:] |= mask[:, :-1]
        mask[:, :-1] |= mask[:, 1:]
    w = np.where(mask, diff, 0.0)
    total = w.sum()
    if total <= 0 or core.sum() < 4:
        return None
    ys, xs = np.indices(w.shape)
    cx, cy = (w * xs).sum() / total, (w * ys).sum() / total
    dx, dy = xs - cx, ys - cy
    cov = np.array([[(w * dx * dx).sum(), (w * dx * dy).sum()],
                    [(w * dx * dy).sum(), (w * dy * dy).sum()]]) / total
    # 픽셀은 면적을 평균하므로 각 축 분산에 1/12px²가 더해진다. 빼지 않으면 작은 공일수록 크게 잰다(6px 공에서 약 0.1px).
    minor, major = np.sqrt(np.clip(np.linalg.eigvalsh(cov) - 1 / 12, 0, None))
    level = np.median(diff[diff > 0.75 * peak])  # 공 안쪽의 밝기 차이
    area = np.clip(w / level, 0, 1).sum()
    # 원판이 길이 L만큼 직선으로 번지면 긴 축 분산이 L²/12만큼 늘어난다.
    blur = np.sqrt(max(12 * (major**2 - minor**2), 0.0))
    return {"cx": cx, "cy": cy, "d_minor": 4 * minor, "d_major": 4 * major, "blur": blur,
            "d_area": 2 * np.sqrt(area / np.pi), "contrast": level}


def fit_bias(distances, diameters):
    """잰 지름 = 기울기 × (1/거리) + 절편. 기울기 = 초점거리 × 공 지름(px·m), 절편 = 치우침(px)."""
    x = 1 / np.asarray(distances, float)
    slope, intercept = np.polyfit(x, np.asarray(diameters, float), 1)
    return slope, intercept


# ---------------------------------------------------------------- 영상 처리 (OpenCV)

def read_gray(path, limit=None):
    import cv2

    capture = cv2.VideoCapture(str(path))
    frames = []
    while limit is None or len(frames) < limit:
        ok, frame = capture.read()
        if not ok:
            break
        frames.append(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float32))
    capture.release()
    if not frames:
        raise ValueError(f"영상을 읽지 못했습니다: {path}")
    return np.stack(frames)


def find_round_blob(image, min_d=4, max_d=300):
    """밝기 차이 지도에서 가장 둥근 덩어리의 (x, y, w, h). 못 찾으면 None."""
    import cv2

    img = np.clip(image, 0, 255).astype(np.uint8)
    _, binary = cv2.threshold(img, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    count, _, stats, _ = cv2.connectedComponentsWithStats(binary)
    best, best_score = None, 0.0
    for x, y, w, h, area in stats[1:count]:
        d = max(w, h)
        if not (min_d <= d <= max_d):
            continue
        roundness = area / (np.pi * d * d / 4) * min(w, h) / d  # 꽉 찬 원이면 1
        if roundness > best_score:
            best, best_score = (int(x), int(y), int(w), int(h)), roundness
    return best


def pad_roi(roi, shape, margin):
    x, y, w, h = roi
    x0, y0 = max(x - margin, 0), max(y - margin, 0)
    x1, y1 = min(x + w + margin, shape[1]), min(y + h + margin, shape[0])
    return x0, y0, x1, y1


def analyze_static(frames, roi=None):
    """멈춘 공. 프레임마다 지름을 재서 중앙값과 흔들림을 낸다."""
    median = np.median(frames, axis=0)
    if roi is None:
        # 배경보다 튀는 둥근 덩어리를 찾는다. 공이 어두운 배경 앞에 있다고 가정한다(촬영 방법 참고).
        local = median - np.median(median)
        roi = find_round_blob(np.abs(local) / max(np.abs(local).max(), 1) * 255)
        if roi is None:
            raise ValueError("공을 찾지 못했습니다. --roi로 위치를 알려주세요")
    x0, y0, x1, y1 = pad_roi(roi, median.shape, max(roi[2], roi[3]) // 2 + 4)
    rows = []
    for i, frame in enumerate(frames):
        patch = frame[y0:y1, x0:x1]
        ring = np.concatenate([patch[0], patch[-1], patch[:, 0], patch[:, -1]])
        m = measure(patch, np.median(ring))
        if m:
            rows.append({"frame": i, "x": m["cx"] + x0, "y": m["cy"] + y0,
                         **{k: m[k] for k in ("d_minor", "d_major", "d_area", "blur")}})
    return rows


def analyze_throw(frames, min_d=4):
    """던진 공. 고정 카메라라 프레임 중앙값이 배경이 되고, 배경과의 차이에서 공을 찾는다."""
    background = np.median(frames, axis=0)
    noise = np.median(np.abs(frames[0] - background)) * 1.4826 + 1.0
    rows = []
    for i, frame in enumerate(frames):
        diff = np.abs(frame - background)
        roi = find_round_blob(np.where(diff > 5 * noise, diff, 0), min_d=min_d)
        if roi is None:
            continue
        x0, y0, x1, y1 = pad_roi(roi, frame.shape, max(roi[2], roi[3]) // 2 + 4)
        m = measure(frame[y0:y1, x0:x1], background[y0:y1, x0:x1])
        if m:
            rows.append({"frame": i, "x": m["cx"] + x0, "y": m["cy"] + y0,
                         **{k: m[k] for k in ("d_minor", "d_major", "d_area", "blur")}})
    return rows


def smoothness(rows, fps):
    """던진 공의 지름 흔들림(px). 거리가 시간에 거의 선형으로 줄므로 1/지름에 2차 곡선을 맞추고 남는 차이를 본다."""
    if len(rows) < 8:
        return None
    t = np.array([r["frame"] for r in rows]) / fps
    d = np.array([r["d_minor"] for r in rows])
    fitted = 1 / np.polyval(np.polyfit(t, 1 / d, 2), t)
    return float(np.std(d - fitted))


# ---------------------------------------------------------------- 실행

def summarize(values):
    v = np.asarray(values, float)
    return float(np.median(v)), float(np.std(v))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("--roi", action="append", default=[], help="영상이름=x,y,w,h (공을 자동으로 못 찾을 때)")
    parser.add_argument("--out", default="runs/ball-size")
    parser.add_argument("--max-frames", type=int, default=2400)
    args = parser.parse_args()

    rois = {name: tuple(int(v) for v in box.split(",")) for name, box in (r.split("=") for r in args.roi)}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    static, throws, focals = [], [], []

    for video in sorted(Path(args.folder).glob("*.mov")):
        info_path = video.with_suffix(".json")
        info = json.loads(info_path.read_text()) if info_path.exists() else {}
        memo = info.get("memo") or video.stem
        fps = info.get("nominal_fps", 240)
        if info.get("field_of_view_deg"):
            focals.append(focal_from_fov(info["field_of_view_deg"]))
        distance = parse_distance(memo)
        kind = "static" if distance else "throw" if "throw" in memo.lower() else None
        if kind is None:
            print(f"건너뜀 (메모에 거리나 throw가 없음): {video.name}")
            continue
        try:
            frames = read_gray(video, args.max_frames)
            rows = analyze_static(frames, rois.get(video.stem)) if kind == "static" else analyze_throw(frames)
        except ValueError as error:
            print(f"실패: {video.name}: {error}")
            continue
        with open(out / f"{video.stem}.csv", "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["frame", "x", "y", "d_minor", "d_major", "d_area", "blur"])
            writer.writeheader()
            writer.writerows(rows)
        exposure = info.get("exposure_seconds")
        record = {"name": video.stem, "rows": rows, "fps": fps, "frames": len(frames),
                  "exposure": f"1/{round(1 / exposure)}초" if exposure else "-", "edge": "edge" in memo.lower()}
        (static if kind == "static" else throws).append({**record, "distance": distance})

    focal = float(np.median(focals)) if focals else None
    print(f"\n화각으로 계산한 초점거리: {focal:.0f}px" if focal else "\n화각 정보 없음 (정보 파일 확인)")

    if static:
        print("\n### 멈춘 공\n")
        print("| 영상 | 거리 (m) | 측정 프레임 | 지름 d_minor (px) | 흔들림 (px) | d_area (px) | 계산값 (px) | 차이 (px) |")
        print("|---|---|---|---|---|---|---|---|")
        center = []
        for s in static:
            if not s["rows"]:
                print(f"| {s['name']} | {s['distance']} | 0 | - | - | - | - | - |")
                continue
            dm, ds = summarize([r["d_minor"] for r in s["rows"]])
            da, _ = summarize([r["d_area"] for r in s["rows"]])
            expected = focal * BALL_DIAMETER / s["distance"] if focal else None
            gap = f"{dm - expected:+.2f}" if expected else "-"
            print(f"| {s['name']} | {s['distance']} | {len(s['rows'])} | {dm:.2f} | {ds:.2f} | {da:.2f} | "
                  f"{expected:.2f} | {gap} |" if expected else f"| {s['name']} | {s['distance']} | {len(s['rows'])} | {dm:.2f} | {ds:.2f} | {da:.2f} | - | - |")
            if not s["edge"]:
                center.append((s["distance"], dm))
        if len({d for d, _ in center}) >= 2:
            slope, intercept = fit_bias(*zip(*center))
            print(f"\n- 맞춘 식: 지름 = {slope:.1f} / 거리 {intercept:+.2f}px")
            print(f"- **치우침(절편): {intercept:+.2f}px**")
            print(f"- 기울기로 구한 초점거리: {slope / BALL_DIAMETER:.0f}px" + (f" (화각 기준 {focal:.0f}px)" if focal else ""))
        else:
            print("\n치우침을 구하려면 화면 가운데에서 찍은 서로 다른 거리가 2개 이상 필요합니다.")

    if throws:
        print("\n### 던진 공\n")
        print("| 영상 | 노출 | 공을 찾은 프레임 | 지름 범위 d_minor (px) | 번짐 길이 중앙값 (px) | 지름 흔들림 (px) |")
        print("|---|---|---|---|---|---|")
        for s in throws:
            rows = s["rows"]
            if not rows:
                print(f"| {s['name']} | {s['exposure']} | 0 / {s['frames']} | - | - | - |")
                continue
            d = [r["d_minor"] for r in rows]
            blur = np.median([r["blur"] for r in rows])
            jitter = smoothness(rows, s["fps"])
            print(f"| {s['name']} | {s['exposure']} | {len(rows)} / {s['frames']} | {min(d):.1f} ~ {max(d):.1f} | "
                  f"{blur:.1f} | {jitter:.2f} |" if jitter is not None else
                  f"| {s['name']} | {s['exposure']} | {len(rows)} / {s['frames']} | {min(d):.1f} ~ {max(d):.1f} | {blur:.1f} | - |")

    print(f"\n프레임별 측정값: {out}/*.csv")


if __name__ == "__main__":
    main()
