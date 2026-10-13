"""카메라 투영과 궤적 복원 점검. 실행: python test_camera.py (또는 pytest)

카메라 위치와 투구 값은 검증용 예시이며 실측값이 아니다.
"""

import numpy as np

from camera import Camera, crossing, positions, reconstruct

CAMERA = Camera.looking_at(position=(0.0, -5.0, 3.0), target=(0.0, 0.0, 0.8), focal=1284.0)
TRUTH = np.array([-0.4, 16.8, 1.8, 0.6, -33.3, -0.8, 1.2, 5.0, -7.3])  # p0, v0, a
TIMES = np.arange(1, 125) / 240.0


def distance(a, b):
    return float(np.hypot(a[0] - b[0], a[1] - b[1]))


def test_target_projects_to_image_center():
    pixels, depth = CAMERA.project([(0.0, 0.0, 0.8)])
    assert np.allclose(pixels[0], [960, 540]) and depth[0] > 0


def test_higher_point_appears_higher_and_right_point_appears_right():
    center, _ = CAMERA.project([(0.0, 0.0, 0.8)])
    up, _ = CAMERA.project([(0.0, 0.0, 1.2)])
    right, _ = CAMERA.project([(0.3, 0.0, 0.8)])
    assert up[0, 1] < center[0, 1] and right[0, 0] > center[0, 0]  # 화면 y는 아래로 증가


def test_ray_point_inverts_projection():
    point = np.array([0.2, 3.0, 1.1])
    pixels, depth = CAMERA.project([point])
    assert np.allclose(CAMERA.ray_point(pixels[0], depth[0]), point)


def test_scaled_trajectory_looks_identical_on_screen():
    # 깊이 모호성: 카메라 중심 기준으로 1.1배 늘린 궤적도 같은 화면 좌표를 만든다.
    points = positions(TRUTH, TIMES)
    scaled = CAMERA.position + 1.1 * (points - CAMERA.position)
    assert np.allclose(CAMERA.project(points)[0], CAMERA.project(scaled)[0])


def test_reconstructs_crossing_with_diameters_and_no_noise():
    points = positions(TRUTH, TIMES)
    pixels, _ = CAMERA.project(points)
    estimate = reconstruct(CAMERA, TIMES, pixels, diameters=CAMERA.apparent_diameter(points))
    assert distance(crossing(estimate), crossing(TRUTH)) < 1e-4


def test_reconstructs_crossing_with_release_prior_and_no_noise():
    pixels, _ = CAMERA.project(positions(TRUTH, TIMES))
    estimate = reconstruct(CAMERA, TIMES, pixels, release_y=TRUTH[1], release_sigma=0.01)
    assert distance(crossing(estimate), crossing(TRUTH)) < 1e-3


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("통과:", name)
