"""카메라 1대로 통과 지점을 얼마나 정확히 복원할 수 있는지 합성 투구로 가늠한다.

실행: python experiment_monocular.py
결과 해석은 docs/experiments/2026-10-13-monocular-reconstruction-sim.md

모든 수치(카메라 위치, 초점거리, 투구 분포, 노이즈 크기)는 가정이다. 실측이 나오면 바꿔 다시 돌린다.
"""

import numpy as np

from camera import BALL_DIAMETER, GRAVITY_Z, Camera, crossing, positions, reconstruct

PITCHES = 300
# 초점거리는 CLAUDE.md의 가정 "5m 거리에서 공 지름 약 19px"에 맞춘 값 (19 * 5 / 0.074).
FOCAL = 1284.0
TARGET = (0.0, 0.0, 0.8)
DRAG = 0.0062  # 1/m. 공기저항 감속 = DRAG * 속도^2 (야구공 대략값)


def make_camera(height=3.0, distance=5.0, pitch_error_deg=0.0, height_error=0.0):
    target = np.array(TARGET) + [0.0, 0.0, np.tan(np.radians(pitch_error_deg)) * distance]
    return Camera.looking_at((0.0, -distance, height + height_error), target, FOCAL)


def random_pitch(rng):
    """릴리스 지점에서 스트라이크존 근처로 가는 일정 가속도 투구 하나 (p0, v0, a)."""
    p0 = np.array([rng.uniform(-0.6, 0.6), 18.44 - rng.uniform(1.5, 2.0), rng.uniform(1.5, 2.0)])
    end = np.array([rng.uniform(-0.35, 0.35), 0.0, rng.uniform(0.4, 1.2)])
    a = np.array([rng.uniform(-4, 4), rng.uniform(3, 7), GRAVITY_Z + rng.uniform(-1, 4)])
    speed = rng.uniform(80, 125) / 3.6
    flight = p0[1] / (speed - 0.5 * a[1] * p0[1] / speed)  # 감속을 감안한 비행 시간 근사
    v0 = (end - p0 - 0.5 * a * flight**2) / flight
    return np.concatenate([p0, v0, a])


def fly(params, fps, drag):
    """프레임 시각과 위치, 실제 통과 지점. drag=True면 속도에 따라 변하는 공기저항으로 날린다."""
    if not drag:
        t_end = np.roots([0.5 * params[7], params[4], params[1]])
        t_end = min(r.real for r in t_end if abs(r.imag) < 1e-9 and r.real > 0)
        t = np.arange(1, int(t_end * fps) + 1) / fps
        return t, positions(params, t), crossing(params)
    # 공기저항은 속도 제곱에 비례, 나머지 힘(중력+회전에 의한 힘)은 일정하다고 둔다.
    p, v = params[0:3].copy(), params[3:6].copy()
    other = params[6:9] - [0.0, params[7], 0.0]
    dt, step, t, points = 1e-4, round(1e4 / fps), [], []
    for i in range(1, 200000):
        v = v + (other - DRAG * np.linalg.norm(v) * v) * dt
        previous, p = p, p + v * dt
        if p[1] < 0:
            w = previous[1] / (previous[1] - p[1])
            hit = previous + w * (p - previous)
            return np.array(t), np.array(points), (hit[0], hit[2])
        if i % step == 0:
            t.append(i * dt)
            points.append(p.copy())
    raise RuntimeError("공이 홈플레이트에 도달하지 않았습니다")


def run(label, *, pixel_sigma=1.0, diameter_sigma=1.0, diameter_bias=0.0, use_diameter=True, use_release=True,
        min_diameter=8.0, hidden_below_y=0.0, fps=240, drag=False, camera_kwargs=None, believed_kwargs=None):
    rng = np.random.default_rng(0)
    camera = make_camera(**(camera_kwargs or {}))  # 실제 카메라
    # 우리가 안다고 믿는 카메라. 따로 주지 않으면 실제와 같다(보정이 정확한 경우).
    believed = make_camera(**(camera_kwargs or {} if believed_kwargs is None else believed_kwargs))
    dx, dz, frames, failed = [], [], [], 0
    for _ in range(PITCHES):
        params = random_pitch(rng)
        t, points, truth = fly(params, fps, drag)
        pixels, _ = camera.project(points)
        diameters = camera.apparent_diameter(points)
        seen = (diameters >= min_diameter) & (points[:, 1] >= hidden_below_y)
        seen &= (pixels[:, 0] >= 0) & (pixels[:, 0] < camera.width) & (pixels[:, 1] >= 0) & (pixels[:, 1] < camera.height)
        if seen.sum() < 8:
            failed += 1
            continue
        noisy_pixels = pixels[seen] + rng.normal(0, pixel_sigma, (seen.sum(), 2))
        noisy_diameters = diameters[seen] + diameter_bias + rng.normal(0, diameter_sigma, seen.sum())
        release_y = params[1] + rng.normal(0, 0.3) if use_release else None
        try:
            estimate = reconstruct(believed, t[seen], noisy_pixels, noisy_diameters if use_diameter else None,
                                   release_y, pixel_sigma, max(diameter_sigma, 0.5))
            x, z = crossing(estimate)
        except (ValueError, FloatingPointError):
            failed += 1
            continue
        dx.append(abs(x - truth[0]) * 100)
        dz.append(abs(z - truth[1]) * 100)
        frames.append(seen.sum())
    q = lambda v, p: f"{np.percentile(v, p):.1f}" if v else "-"
    print(f"| {label} | {q(dx, 50)} | {q(dx, 90)} | {q(dz, 50)} | {q(dz, 90)} | {int(np.median(frames)) if frames else 0} | {failed} |")


def table(title):
    print(f"\n### {title}\n")
    print("| 조건 | 좌우 오차 중앙값 (cm) | 좌우 90% | 상하 오차 중앙값 (cm) | 상하 90% | 관측 프레임 | 실패 |")
    print("|---|---|---|---|---|---|---|")


if __name__ == "__main__":
    np.seterr(all="ignore")

    table("1. 깊이 정보에 따른 차이 (전 구간 관측, 화면 노이즈 1px)")
    run("화면 좌표만", use_diameter=False, use_release=False, min_diameter=0)
    run("+ 공 지름 (노이즈 1px)", use_release=False, min_diameter=0)
    run("+ 공 지름 (노이즈 2px)", diameter_sigma=2.0, use_release=False, min_diameter=0)
    run("+ 공 지름 (노이즈 1px, 항상 1px 크게 잼)", diameter_bias=1.0, use_release=False, min_diameter=0)
    run("+ 릴리스 위치 (±0.3m)", use_diameter=False, min_diameter=0)
    run("+ 공 지름 + 릴리스 위치", min_diameter=0)

    table("2. 공이 작을 때는 못 본다고 가정 (지름 N px 이상만 관측)")
    for d in (0, 6, 8, 10, 12):
        run(f"{d}px 이상, 지름 + 릴리스", min_diameter=d)
    run("8px 이상, 지름만", use_release=False)
    run("8px 이상, 릴리스만", use_diameter=False)

    table("3. 홈플레이트 앞 가림 (기준 조건: 8px 이상, 지름 + 릴리스)")
    for y in (0.0, 0.5, 1.0, 2.0, 3.0):
        run(f"홈플레이트 앞 {y}m 구간이 가려짐", hidden_below_y=y)

    table("4. 검출 위치 노이즈 (기준 조건)")
    for s in (0.5, 1.0, 2.0, 3.0):
        run(f"화면 노이즈 {s}px", pixel_sigma=s)

    table("5. 카메라 보정이 틀렸을 때 (기준 조건)")
    run("보정 정확", camera_kwargs={})
    run("기울기 0.1도 틀림", camera_kwargs={"pitch_error_deg": 0.1}, believed_kwargs={})
    run("기울기 0.3도 틀림", camera_kwargs={"pitch_error_deg": 0.3}, believed_kwargs={})
    run("기울기 0.5도 틀림", camera_kwargs={"pitch_error_deg": 0.5}, believed_kwargs={})
    run("높이 5cm 틀림", camera_kwargs={"height_error": 0.05}, believed_kwargs={})
    run("높이 10cm 틀림", camera_kwargs={"height_error": 0.10}, believed_kwargs={})

    table("6. 카메라 높이 (기준 조건)")
    for h in (1.5, 2.0, 3.0, 4.0):
        run(f"높이 {h}m", camera_kwargs={"height": h})

    table("7. 프레임레이트와 물리 모델 (기준 조건)")
    run("240fps, 일정 가속도")
    run("120fps, 일정 가속도", fps=120)
    run("240fps, 속도에 따라 변하는 공기저항", drag=True)
    run("240fps, 변하는 공기저항 + 앞 1m 가림", drag=True, hidden_below_y=1.0)
