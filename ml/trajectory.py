"""합성 투구 궤적 생성과 홈플레이트 통과 지점 추정.

좌표계는 docs/interface-spec.md를 따른다 (단위 m).
원점: 홈플레이트 앞면 중앙의 지면 / x: 포수 시점 오른쪽 / y: 투수 방향 / z: 위
"""

import numpy as np

GRAVITY = (0.0, 0.0, -9.81)


def _first_root(a, b, c, t_min):
    """a*t^2 + b*t + c = 0 의 해 중 t_min 이후 가장 이른 것."""
    if abs(a) < 1e-12:
        if abs(b) < 1e-12:
            raise ValueError("공이 홈플레이트 방향으로 움직이지 않습니다")
        roots = [-c / b]
    else:
        disc = b * b - 4 * a * c
        if disc < 0:
            raise ValueError("궤적이 홈플레이트 평면(y=0)에 닿지 않습니다")
        # 뺄셈으로 유효숫자를 잃지 않는 형태 (a가 아주 작을 때도 안정적)
        q = -0.5 * (b + np.copysign(np.sqrt(disc), b))
        roots = [q / a] + ([c / q] if q != 0 else [])
    later = [t for t in roots if t >= t_min]
    if not later:
        raise ValueError("궤적이 홈플레이트 평면(y=0)에 닿지 않습니다")
    return min(later)


def simulate(p0, v0, accel=GRAVITY, fps=240.0):
    """릴리스 지점 p0, 초기 속도 v0, 일정한 가속도 accel로 날아가는 공.

    반환: (프레임 시각 배열, 프레임별 xyz 배열, 실제 통과 지점 (x, z))
    프레임은 공이 홈플레이트 평면(y=0)을 지나기 전까지만 만든다.
    """
    # ponytail: 가속도를 상수로 둔 모델. 실제 공기저항·마그누스 힘은 속도에 따라 변한다.
    # 실측 궤적과 차이가 보이면 속도 의존 항력 모델로 바꾼다.
    p0, v0, accel = (np.asarray(v, dtype=float) for v in (p0, v0, accel))
    t_cross = _first_root(0.5 * accel[1], v0[1], p0[1], 0.0)
    t = np.arange(0.0, t_cross, 1.0 / fps)
    position = lambda s: p0 + v0 * s + 0.5 * accel * s * s
    points = np.array([position(s) for s in t])
    crossing = position(t_cross)
    return t, points, (crossing[0], crossing[2])


def fit_crossing(t, points):
    """관측된 (시각, xyz)에 2차 곡선을 맞춰 홈플레이트 평면(y=0) 통과 지점 (x, z)를 추정한다.

    가림으로 빠진 프레임은 그냥 넘기지 않으면 된다. 시각이 등간격일 필요는 없다.
    """
    t = np.asarray(t, dtype=float)
    points = np.asarray(points, dtype=float)
    if len(t) < 3 or points.shape != (len(t), 3):
        raise ValueError("관측점이 3개 이상 필요합니다 (시각 N개, 좌표 N×3)")
    coef = np.polyfit(t, points, 2)  # 행: t^2, t, 1 / 열: x, y, z
    t_cross = _first_root(coef[0, 1], coef[1, 1], coef[2, 1], t[0])
    x, _, z = coef[0] * t_cross**2 + coef[1] * t_cross + coef[2]
    return x, z
