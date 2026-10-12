"""공 중심을 히트맵으로 찾는 소형 모델.

박스가 아니라 중심점을 낸다. 궤적 계산에 필요한 것이 중심점이고, 공이 10~20px로 작아서
박스 검출기의 기본 앵커(32px~)에는 잘 맞지 않기 때문이다.
출력 히트맵은 입력의 1/2 해상도다.
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision.models import ResNet18_Weights, resnet18

STRIDE = 2
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


def _block(cin, cout):
    return nn.Sequential(nn.Conv2d(cin, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True))


class BallNet(nn.Module):
    def __init__(self, pretrained=True):
        super().__init__()
        # ResNet-18의 앞부분만 쓴다(1/8 해상도까지). torchvision 코드는 BSD-3 라이선스.
        net = resnet18(weights=ResNet18_Weights.DEFAULT if pretrained else None)
        self.stem = nn.Sequential(net.conv1, net.bn1, net.relu)  # 1/2, 64ch
        self.layer1 = nn.Sequential(net.maxpool, net.layer1)  # 1/4, 64ch
        self.layer2 = net.layer2  # 1/8, 128ch
        self.up1 = _block(128 + 64, 64)
        self.up2 = _block(64 + 64, 32)
        self.head = nn.Conv2d(32, 1, 1)
        nn.init.constant_(self.head.bias, -4.0)  # 처음에는 거의 모든 곳이 '공 없음'

    def forward(self, x):
        s2 = self.stem(x)
        s4 = self.layer1(s2)
        s8 = self.layer2(s4)
        y = self.up1(torch.cat([F.interpolate(s8, size=s4.shape[-2:], mode="nearest"), s4], 1))
        y = self.up2(torch.cat([F.interpolate(y, size=s2.shape[-2:], mode="nearest"), s2], 1))
        return self.head(y)  # 로짓


def make_target(height, width, balls):
    """입력 크기 (height, width)와 공 [(cx, cy, size)]로 1/2 해상도 정답 히트맵을 만든다."""
    h, w = height // STRIDE, width // STRIDE
    target = torch.zeros(h, w)
    ys = torch.arange(h).view(-1, 1)
    xs = torch.arange(w).view(1, -1)
    for cx, cy, size in balls:
        sigma = max(1.5, size / STRIDE / 4)
        g = torch.exp(-((xs - cx / STRIDE) ** 2 + (ys - cy / STRIDE) ** 2) / (2 * sigma**2))
        target = torch.maximum(target, g)
    return target


def focal_loss(logits, target):
    """CenterNet 방식 손실. 공 중심 근처는 덜 벌점 준다."""
    p = torch.sigmoid(logits).clamp(1e-4, 1 - 1e-4)
    positive = target.ge(0.99).float()
    pos = -((1 - p) ** 2) * torch.log(p) * positive
    neg = -((1 - target) ** 4) * (p**2) * torch.log(1 - p) * (1 - positive)
    return (pos.sum() + neg.sum()) / positive.sum().clamp(min=1)


def find_peaks(logits, threshold=0.3, max_peaks=5):
    """히트맵 한 장(H, W 로짓)에서 [(x, y, 점수)]를 점수 높은 순으로 돌려준다. 좌표는 입력 px."""
    p = torch.sigmoid(logits)[None, None]
    is_peak = (F.max_pool2d(p, 9, stride=1, padding=4) == p) & (p >= threshold)
    scores = (p * is_peak)[0, 0]
    top = torch.topk(scores.flatten(), min(max_peaks, scores.numel()))
    width = scores.shape[1]
    return [(int(i % width) * STRIDE, int(i // width) * STRIDE, float(s)) for s, i in zip(top.values, top.indices) if s > 0]
