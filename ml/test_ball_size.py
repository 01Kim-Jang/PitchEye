"""공 크기 측정 점검. 실행: python test_ball_size.py (또는 pytest)

화면에 공을 그린 합성 이미지로, 지름을 알고 있는 상태에서 측정이 맞는지 본다.
"""

import numpy as np

from ball_size import fit_bias, focal_from_fov, measure, parse_distance


def disk(size, cx, cy, d, blur=0.0, angle=0.0, level=200.0, background=30.0, oversample=8):
    """지름 d(px)의 밝은 원판. blur>0이면 angle 방향으로 blur px만큼 번진다(움직이는 공)."""
    n = size * oversample
    ys, xs = (np.indices((n, n)) + 0.5) / oversample
    image = np.zeros((n, n))
    steps = max(1, int(blur * 4))
    for s in np.linspace(-blur / 2, blur / 2, steps):
        ox, oy = cx + s * np.cos(angle), cy + s * np.sin(angle)
        image += ((xs - ox) ** 2 + (ys - oy) ** 2) <= (d / 2) ** 2
    image /= steps
    image = image.reshape(size, oversample, size, oversample).mean(axis=(1, 3))
    return background + (level - background) * image


def test_parse_distance():
    assert parse_distance("3m") == 3.0
    assert parse_distance("2.5m") == 2.5
    assert parse_distance("250cm") == 2.5
    assert parse_distance("5m-edge") == 5.0
    assert parse_distance("throw") is None
    assert parse_distance("") is None


def test_static_disk_diameter_is_measured_within_a_tenth_of_a_pixel():
    for d in (6.0, 10.0, 19.0, 33.0):
        m = measure(disk(80, 40.3, 39.7, d), 30.0)
        assert abs(m["d_minor"] - d) < 0.1, (d, m)
        assert abs(m["d_area"] - d) < 0.1, (d, m)
        # disk()는 픽셀 경계가 정수인 좌표로 그리고, measure()는 픽셀 중심이 정수인 좌표로 낸다(0.5px 차이).
        assert abs(m["cx"] - 39.8) < 0.05 and abs(m["cy"] - 39.2) < 0.05


def test_motion_blur_stretches_only_the_long_axis():
    m = measure(disk(120, 60, 60, 14.0, blur=30.0, angle=0.6), 30.0)
    assert abs(m["d_minor"] - 14.0) < 0.15, m
    assert abs(m["blur"] - 30.0) < 1.0, m


def test_dark_ball_on_bright_background():
    m = measure(disk(80, 40, 40, 12.0, level=40.0, background=220.0), 220.0)
    assert abs(m["d_minor"] - 12.0) < 0.1, m


def test_noise_does_not_bias_the_median():
    rng = np.random.default_rng(0)
    clean = disk(80, 40, 40, 12.0)
    values = [measure(clean + rng.normal(0, 3, clean.shape), 30.0)["d_minor"] for _ in range(50)]
    assert abs(np.median(values) - 12.0) < 0.2, np.median(values)


def test_fit_recovers_known_bias():
    distances = np.array([2.0, 3.0, 5.0, 7.0, 10.0])
    true = 1284 * 0.074 / distances
    slope, intercept = fit_bias(distances, true + 1.0)  # 항상 1px 크게 잰 경우
    assert abs(intercept - 1.0) < 1e-9 and abs(slope - 1284 * 0.074) < 1e-6


def test_focal_from_field_of_view():
    assert abs(focal_from_fov(90.0) - 960.0) < 1e-6


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("통과:", name)
