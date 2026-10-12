"""AI Hub '야구 주요 규칙 판정 영상 데이터'(dataSetSn=71726) 라벨 읽기.

라벨 JSON 하나가 이미지 하나에 대응하고, 공은 label이 'Baseball_ball'인 box로 들어 있다.
숫자가 문자열로 저장되어 있어 float로 바꿔 쓴다.
"""

import json
import re
import zlib
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Sample:
    image: Path
    session: str  # 같은 촬영(여러 카메라)을 묶는 키. 학습/검증을 나눌 때 이 단위로 나눈다.
    kind: str  # 스트라익_볼, 파울_페어 ...
    balls: list  # [(중심 x, 중심 y, 크기 px)]


def parse_balls(label: dict) -> list:
    balls = []
    for annotation in label.get("annotation", []):
        box = annotation.get("box")
        if box and box.get("label") == "Baseball_ball":
            for loc in box["location"]:
                x, y, w, h = (float(loc[k]) for k in ("x", "y", "width", "height"))
                balls.append((x + w / 2, y + h / 2, max(w, h)))
    return balls


def session_of(stem: str) -> str:
    # 예: ST_01_Y20230830_T103336_CAM050000_Y01_f000043 → Y20230830_T103336
    match = re.search(r"Y\d{8}_T\d{6}", stem)
    return match.group(0) if match else stem


def load_samples(root) -> list:
    root = Path(root)
    images = {p.stem: p for p in root.rglob("*.jpg")}
    samples = []
    for path in sorted(root.rglob("*.json")):
        if path.stem not in images:
            continue
        label = json.loads(path.read_text(encoding="utf-8-sig"))
        samples.append(Sample(images[path.stem], session_of(path.stem), path.parent.parent.name, parse_balls(label)))
    return samples


def is_validation(session: str, every: int = 5) -> bool:
    """촬영 단위로 약 1/every를 검증용으로 뺀다. 같은 투구를 다른 카메라로 찍은 장면이 양쪽에 섞이지 않게 한다."""
    return zlib.crc32(session.encode()) % every == 0
