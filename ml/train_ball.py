"""공 검출 모델 학습과 평가.

실행 예:
    python train_ball.py --data ../data/raw/aihub/71726 --epochs 150

학습은 공 주변을 잘라서(CROP px, 크기를 0.6~1.4배로 바꿔 가며) 하고, 평가는 1920x1080 전체 이미지로 한다.
결과는 runs/<이름>/ 아래 model.pt, metrics.json으로 남는다.
에폭마다 checkpoint.pt를 저장하므로, 중간에 꺼져도 같은 명령을 다시 실행하면 이어서 학습한다.
"""

import argparse
import json
import os
import random
import statistics
import time
from pathlib import Path

import torch
import torch.nn.functional as F
from PIL import Image, ImageEnhance
from torch.utils.data import DataLoader, Dataset
from torchvision.transforms.functional import normalize, to_tensor

from aihub import is_validation, load_samples
from ball_model import MEAN, STD, BallNet, find_peaks, focal_loss, make_target

CROP = 192  # M1에서 한 스텝 시간이 조각 넓이에 비례한다. 작게 잘라 같은 시간에 더 많이 학습한다.


def to_input(image):
    return normalize(to_tensor(image), MEAN, STD)


class CropDataset(Dataset):
    """이미지마다 CROP 크기 조각 하나. 공이 있으면 대부분 공이 들어오게 자른다."""

    def __init__(self, samples):
        self.samples = samples

    def __len__(self):
        return len(self.samples)

    def __getitem__(self, index):
        sample = self.samples[index]
        image = Image.open(sample.image).convert("RGB")
        width, height = image.size
        scale = random.uniform(0.6, 1.4)  # 1보다 작으면 공이 더 작아진다 (작은 공 사례를 늘린다)
        source = round(CROP / scale)  # 원본에서 잘라낼 한 변
        if sample.balls and random.random() < 0.6:
            cx, cy, _ = random.choice(sample.balls)
            margin = round(16 / scale)  # 공이 조각 가장자리에 걸리지 않게
            left = int(cx) - random.randint(margin, source - margin)
            top = int(cy) - random.randint(margin, source - margin)
        else:
            left, top = random.randint(0, width - source), random.randint(0, height - source)
        left = min(max(left, 0), width - source)
        top = min(max(top, 0), height - source)
        crop = image.crop((left, top, left + source, top + source)).resize((CROP, CROP), Image.BILINEAR)
        balls = [((x - left) * scale, (y - top) * scale, s * scale) for x, y, s in sample.balls
                 if 0 <= x - left < source and 0 <= y - top < source]

        if random.random() < 0.5:
            crop = crop.transpose(Image.FLIP_LEFT_RIGHT)
            balls = [(CROP - 1 - x, y, s) for x, y, s in balls]
        crop = ImageEnhance.Brightness(crop).enhance(random.uniform(0.7, 1.3))
        crop = ImageEnhance.Contrast(crop).enhance(random.uniform(0.8, 1.2))
        return to_input(crop), make_target(CROP, CROP, balls)


@torch.no_grad()
def predict(model, sample, device):
    """전체 이미지에서 봉우리 [(x, y, 점수)]를 찾는다. 임계값 0.05로 넉넉히 뽑고 평가에서 거른다."""
    image = to_input(Image.open(sample.image).convert("RGB"))
    _, h, w = image.shape
    image = F.pad(image, (0, -w % 16, 0, -h % 16))  # 16의 배수로
    logits = model(image[None].to(device))[0, 0].cpu()
    return find_peaks(logits[: h // 2, : w // 2], threshold=0.05, max_peaks=5)


def evaluate(samples, predictions, threshold):
    """공 중심에서 max(8, 공 크기) px 안에 봉우리가 있으면 찾은 것으로 본다."""
    hits, errors, peaks_total, ball_images, top1 = 0, [], 0, 0, 0
    empty_images, empty_with_peak = 0, 0
    by_size = {"<10px": [0, 0], "10-20px": [0, 0], ">20px": [0, 0]}
    for sample, peaks in zip(samples, predictions):
        kept = [p for p in peaks if p[2] >= threshold]
        peaks_total += len(kept)
        if not sample.balls:
            empty_images += 1
            empty_with_peak += bool(kept)
            continue
        cx, cy, size = sample.balls[0]
        radius = max(8.0, size)
        distance = lambda p: ((p[0] - cx) ** 2 + (p[1] - cy) ** 2) ** 0.5
        ball_images += 1
        bucket = by_size["<10px" if size < 10 else "10-20px" if size <= 20 else ">20px"]
        bucket[1] += 1
        if peaks and distance(peaks[0]) <= radius:  # 임계값과 무관: 가장 센 봉우리가 공인가
            top1 += 1
        near = [distance(p) for p in kept if distance(p) <= radius]
        if near:
            hits += 1
            bucket[0] += 1
            errors.append(min(near))
    return {
        "threshold": threshold,
        "ball_images": ball_images,
        "recall": round(hits / max(ball_images, 1), 3),
        "precision": round(hits / max(peaks_total, 1), 3),
        "top1_hit_rate": round(top1 / max(ball_images, 1), 3),
        "center_error_px_median": round(statistics.median(errors), 2) if errors else None,
        "center_error_px_p90": round(sorted(errors)[int(len(errors) * 0.9)], 2) if errors else None,
        "no_ball_images": empty_images,
        "no_ball_images_with_false_peak": empty_with_peak,
        "recall_by_ball_size": {k: f"{h}/{n}" for k, (h, n) in by_size.items()},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True)
    parser.add_argument("--epochs", type=int, default=150)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--name", default="ball")
    parser.add_argument("--kinds", nargs="*", help="특정 상황만 사용 (예: 스트라익_볼)")
    args = parser.parse_args()

    random.seed(0)
    torch.manual_seed(0)
    device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"

    samples = load_samples(args.data)
    if args.kinds:
        samples = [s for s in samples if s.kind in args.kinds]
    train = [s for s in samples if not is_validation(s.session)]
    val = [s for s in samples if is_validation(s.session)]
    assert train and val, "데이터를 찾지 못했습니다"
    print(f"장치 {device} / 학습 {len(train)}장 / 검증 {len(val)}장 (촬영 단위로 분리)")

    model = BallNet().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    loader = DataLoader(CropDataset(train), batch_size=args.batch, shuffle=True, num_workers=2, drop_last=True,
                        persistent_workers=True)
    scheduler = torch.optim.lr_scheduler.OneCycleLR(optimizer, max_lr=args.lr, total_steps=args.epochs * len(loader))

    out = Path("runs") / args.name
    out.mkdir(parents=True, exist_ok=True)
    checkpoint = out / "checkpoint.pt"
    first_epoch, elapsed_before = 0, 0.0
    if checkpoint.exists():
        state = torch.load(checkpoint, map_location=device)
        if state["epochs"] == args.epochs:  # 에폭 수가 다르면 학습률 일정이 달라지므로 처음부터 한다
            model.load_state_dict(state["model"])
            optimizer.load_state_dict(state["optimizer"])
            scheduler.load_state_dict(state["scheduler"])
            first_epoch, elapsed_before = state["epoch"], state["elapsed"]
            print(f"{first_epoch}에폭까지 한 기록에서 이어서 학습합니다")

    started = time.time() - elapsed_before
    for epoch in range(first_epoch, args.epochs):
        model.train()
        total = 0.0
        for image, target in loader:
            loss = focal_loss(model(image.to(device))[:, 0], target.to(device))
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            scheduler.step()
            total += loss.item()
        print(f"epoch {epoch + 1}/{args.epochs} loss {total / len(loader):.4f} ({time.time() - started:.0f}s)", flush=True)
        # 임시 파일에 쓰고 바꿔치기한다. 저장 도중 꺼져도 직전 기록이 남는다.
        torch.save({"model": model.state_dict(), "optimizer": optimizer.state_dict(), "scheduler": scheduler.state_dict(),
                    "epoch": epoch + 1, "epochs": args.epochs, "elapsed": time.time() - started}, out / "checkpoint.tmp")
        os.replace(out / "checkpoint.tmp", checkpoint)

    model.eval()
    predictions = [predict(model, s, device) for s in val]
    sweep = [evaluate(val, predictions, t) for t in (0.1, 0.2, 0.3, 0.5, 0.7)]
    result = {
        "data": str(args.data), "kinds": args.kinds, "epochs": args.epochs, "device": device,
        "train_images": len(train), "val_images": len(val),
        "train_seconds": round(time.time() - started),
        "note": "임계값별 수치는 같은 검증 데이터에서 본 것이라, 임계값을 여기서 고르면 낙관적이다.",
        "by_threshold": sweep,
        "by_kind_at_0.3": {k: evaluate([s for s in val if s.kind == k],
                                       [p for s, p in zip(val, predictions) if s.kind == k], 0.3)
                           for k in sorted({s.kind for s in val})},
    }
    torch.save(model.state_dict(), out / "model.pt")
    (out / "metrics.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(sweep, ensure_ascii=False, indent=1))
    checkpoint.unlink(missing_ok=True)
    print("저장:", out)


if __name__ == "__main__":
    main()
