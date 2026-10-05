# 모듈 입출력 스펙 (초안 v0.1)

> 오프라인 Python 파이프라인과 iOS(Core ML) 버전이 **같은 입출력**을 쓴다. 그래야 이식 후 결과를 그대로 비교할 수 있다.
> 필드 추가는 자유, 이름 변경·삭제는 두 개발자 합의 후 `schema_version`을 올린다.

## 좌표계 (홈플레이트 기준, 단위 m)
- 원점: 홈플레이트 앞면 중앙의 지면
- x: 포수가 보는 방향 기준 오른쪽 (+)
- y: 투수 방향 (+)
- z: 위 (+)
- 통과 지점은 `y = 0` 평면에서의 `(x, z)`. 판정 평면을 앞면으로 할지 다른 깊이로 할지는 `[__]` (적용 규정 확인).

## 입력: 캡처 → 판정 (B → A)
```json
{
  "schema_version": "0.1",
  "clip_id": "20261010_venueA_s01_p012",
  "device": "iPhone [__]",
  "width": 1920,
  "height": 1080,
  "fps": 240,
  "frame_timestamps_s": [0.0, 0.004167, 0.008333],
  "frames": "clip.mov",
  "camera": {
    "intrinsics": null,
    "home_plate_px": [[0, 0], [0, 0], [0, 0], [0, 0], [0, 0]]
  },
  "batter": { "height_cm": 175, "side": "R" }
}
```
- `frame_timestamps_s`: 프레임별 실제 타임스탬프. fps로 계산하지 않는다 (프레임 드롭 검출용).
- `camera.intrinsics`: 얻을 수 있으면 채우고, 없으면 `null`.
- `home_plate_px`: 홈플레이트 5개 꼭짓점의 화면 좌표. 순서는 `labeling-rules.md`와 동일.
- `batter.height_cm`의 입력 방식(수동 입력·추정)은 `[__]`.

## 출력: 판정 → 화면 (A → B)
```json
{
  "schema_version": "0.1",
  "clip_id": "20261010_venueA_s01_p012",
  "verdict": "HOLD",
  "confidence": 0.0,
  "hold_reason": "occlusion",
  "crossing": { "x_m": 0.0, "z_m": 0.0, "sigma_x_m": 0.0, "sigma_z_m": 0.0 },
  "zone": { "x_min_m": 0.0, "x_max_m": 0.0, "z_min_m": 0.0, "z_max_m": 0.0 },
  "trajectory": [ { "t_s": 0.0, "x_m": 0.0, "y_m": 0.0, "z_m": 0.0, "observed": true } ],
  "detections_used": 0,
  "occluded_frames": 0,
  "pipeline_version": "offline-0.0"
}
```
- `verdict`: `STRIKE` | `BALL` | `HOLD` (판정 보류)
- `confidence`: 0~1. 계산 방법과 보류 임계값은 실측 후 결정 `[__]`.
- `hold_reason`: `occlusion` | `too_few_detections` | `near_edge` | `frame_drop` | `calibration` | `null`
- `crossing.sigma_*`: 통과 지점 추정의 불확실성. 신뢰도와 보류 판단의 근거.
- `trajectory[].observed`: 실제 검출된 점이면 `true`, 피팅으로 추정한 점이면 `false`.
- 위 예시의 숫자는 **자리 표시**이며 실제 결과가 아니다.

## 화면 표시 규칙
- `HOLD`일 때는 통과 지점을 단정적으로 그리지 않는다.
- 모든 결과 화면에 "참고용 — 최종 판정은 심판" 문구를 표시한다.
