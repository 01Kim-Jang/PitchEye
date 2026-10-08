"""합성 궤적으로 궤적 피팅을 검증한다. 실행: python test_trajectory.py (또는 pytest)

아래 투구 값은 검증용으로 고른 예시이며 실측값이 아니다.
"""

import numpy as np

from trajectory import GRAVITY, fit_crossing, simulate

# 약 120km/h 직구 비슷한 예시: 릴리스 지점, 초기 속도, 가속도(중력 + 임의의 감속·휨)
P0 = (-0.4, 16.8, 1.8)
V0 = (0.6, -33.3, -0.8)
ACCEL = (1.2, 5.0, GRAVITY[2] + 2.5)


def distance(a, b):
    return float(np.hypot(a[0] - b[0], a[1] - b[1]))


def test_recovers_crossing_without_noise():
    t, points, truth = simulate(P0, V0, ACCEL)
    assert distance(fit_crossing(t, points), truth) < 1e-6


def test_recovers_crossing_when_last_frames_are_occluded():
    # 홈플레이트 직전 프레임이 포수·심판에 가려 빠진 상황
    t, points, truth = simulate(P0, V0, ACCEL)
    assert distance(fit_crossing(t[:-30], points[:-30]), truth) < 1e-6


def test_recovers_crossing_with_gap_in_the_middle():
    t, points, truth = simulate(P0, V0, ACCEL)
    keep = np.r_[0:40, 80:len(t)]
    assert distance(fit_crossing(t[keep], points[keep]), truth) < 1e-6


def test_gravity_only_pitch():
    # y 방향 가속도가 0이면 통과 시각 방정식이 1차가 된다
    t, points, truth = simulate(P0, V0)
    assert distance(fit_crossing(t, points), truth) < 1e-6


def test_rejects_too_few_points():
    t, points, _ = simulate(P0, V0, ACCEL)
    try:
        fit_crossing(t[:2], points[:2])
    except ValueError:
        return
    raise AssertionError("관측점 2개로는 실패해야 한다")


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("통과:", name)
