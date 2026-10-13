"""카메라 1대의 화면 좌표에서 3차원 투구 궤적을 복원한다.

좌표계는 docs/interface-spec.md (원점: 홈플레이트 앞면 중앙 지면, x 오른쪽, y 투수 방향, z 위, 단위 m).

핵심 사실: 화면 좌표만으로는 깊이가 정해지지 않는다. 궤적 전체를 카메라 중심 기준으로 s배 늘린
궤적도 똑같은 화면 좌표를 만들고, 그것 역시 일정 가속도 궤적이다(test_camera.py에 확인 코드).
그래서 깊이를 정해 줄 추가 정보가 필요하다. 여기서는 두 가지를 쓸 수 있다.
  - 공의 겉보기 지름 (실제 지름을 알기 때문에 거리를 알 수 있다)
  - 릴리스 지점의 대략적 위치 (투수판에서 얼마나 앞에서 던지는지)
"""

from dataclasses import dataclass

import numpy as np
from scipy.optimize import least_squares

BALL_DIAMETER = 0.074  # m. 규격 둘레 22.9~23.5cm의 중간값
GRAVITY_Z = -9.81


@dataclass
class Camera:
    position: np.ndarray  # 카메라 중심 (m)
    rotation: np.ndarray  # 세계 → 카메라 회전 (3x3). 카메라 좌표는 x 오른쪽, y 아래, z 앞
    focal: float  # 초점거리 (px)
    width: int = 1920
    height: int = 1080

    @classmethod
    def looking_at(cls, position, target, focal, **kwargs):
        position = np.asarray(position, dtype=float)
        forward = np.asarray(target, dtype=float) - position
        forward /= np.linalg.norm(forward)
        right = np.cross(forward, [0.0, 0.0, 1.0])
        right /= np.linalg.norm(right)
        down = np.cross(forward, right)
        return cls(position, np.stack([right, down, forward]), focal, **kwargs)

    def project(self, points):
        """세계 좌표 (N,3) → 화면 좌표 (N,2)와 카메라 앞 방향 깊이 (N,)."""
        cam = (np.atleast_2d(points) - self.position) @ self.rotation.T
        depth = cam[:, 2]
        pixels = self.focal * cam[:, :2] / depth[:, None] + [self.width / 2, self.height / 2]
        return pixels, depth

    def apparent_diameter(self, points):
        """공의 겉보기 지름 (px)."""
        return self.focal * BALL_DIAMETER / self.project(points)[1]

    def ray_point(self, pixel, depth):
        """화면 좌표와 깊이로 세계 좌표를 되돌린다 (초기값 계산용)."""
        cam = np.array([(pixel[0] - self.width / 2) / self.focal, (pixel[1] - self.height / 2) / self.focal, 1.0]) * depth
        return cam @ self.rotation + self.position


def positions(params, t):
    p0, v0, a = params[0:3], params[3:6], params[6:9]
    t = np.asarray(t, dtype=float)[:, None]
    return p0 + v0 * t + 0.5 * a * t * t


def crossing(params):
    """홈플레이트 평면(y=0)을 지나는 지점 (x, z)."""
    from trajectory import _first_root

    t = _first_root(0.5 * params[7], params[4], params[1], 0.0)
    x, _, z = positions(params, [t])[0]
    return x, z


def reconstruct(camera, t, pixels, diameters=None, release_y=None,
                pixel_sigma=1.0, diameter_sigma=1.0, release_sigma=0.3):
    """화면 관측에서 궤적 파라미터 9개 (p0, v0, a)를 추정한다. t=0이 릴리스 시각이다.

    t, pixels: 공이 검출된 프레임의 시각과 화면 좌표. 가려진 프레임은 빼고 넘기면 된다.
    diameters: 같은 프레임의 겉보기 지름 (px). 없으면 None.
    release_y: 릴리스 지점의 y에 대한 사전 추정 (m). 없으면 None.
    둘 다 없으면 깊이가 정해지지 않아 결과를 믿을 수 없다.
    """
    t = np.asarray(t, dtype=float)
    pixels = np.asarray(pixels, dtype=float)

    def residuals(params):
        points = positions(params, t)
        predicted, depth = camera.project(points)
        parts = [((predicted - pixels) / pixel_sigma).ravel()]
        if diameters is not None:
            parts.append((camera.focal * BALL_DIAMETER / depth - diameters) / diameter_sigma)
        if release_y is not None:
            parts.append([(params[1] - release_y) / release_sigma])
        return np.concatenate(parts)

    # 초기값: 첫 관측과 마지막 관측의 깊이를 대략 정해 직선으로 잇고, 가속도는 중력만.
    if diameters is not None:
        depth_first, depth_last = (camera.focal * BALL_DIAMETER / np.median(d) for d in (diameters[:5], diameters[-5:]))
    else:
        depth_first, depth_last = 15.0, 6.0
    first, last = camera.ray_point(pixels[0], depth_first), camera.ray_point(pixels[-1], depth_last)
    a0 = np.array([0.0, 0.0, GRAVITY_Z])
    span = t[-1] - t[0]
    v_mid = (last - first) / span  # 구간 평균 속도 = 구간 중간 시각의 속도
    v0 = v_mid - a0 * (t[0] + t[-1]) / 2
    p0 = first - v0 * t[0] - 0.5 * a0 * t[0] ** 2
    result = least_squares(residuals, np.concatenate([p0, v0, a0]), method="lm")
    return result.x
