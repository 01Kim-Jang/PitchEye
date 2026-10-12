"""공 검출 코드 점검. 실행: python test_ball.py (또는 pytest). 실제 데이터 없이 돈다."""

import torch

from aihub import is_validation, parse_balls, session_of
from ball_model import BallNet, find_peaks, focal_loss, make_target


def test_parse_balls_reads_string_numbers_and_ignores_other_labels():
    label = {"annotation": [
        {"box": {"label": "Baseball_ball", "location": [{"x": "100", "y": "50", "width": "18", "height": "14"}]}},
        {"box": {"label": "Pitcher", "location": [{"x": "0", "y": "0", "width": "90", "height": "200"}]}},
        {"polygon": {"label": "Fair_zone", "location": []}},
    ]}
    assert parse_balls(label) == [(109.0, 57.0, 18.0)]


def test_same_pitch_from_two_cameras_shares_a_session():
    a = session_of("ST_01_Y20230830_T103336_CAM050000_Y01_f000043")
    b = session_of("ST_01_Y20230830_T103336_CAM030000_Y01_f000051")
    assert a == b == "Y20230830_T103336"
    assert is_validation(a) == is_validation(b)


def test_target_peak_is_found_at_ball_center():
    target = make_target(320, 320, [(200, 120, 16)])
    logits = torch.logit(target.clamp(1e-4, 1 - 1e-4))
    x, y, score = find_peaks(logits)[0]
    assert abs(x - 200) <= 2 and abs(y - 120) <= 2 and score > 0.9


def test_no_peaks_on_empty_heatmap():
    assert find_peaks(torch.full((160, 160), -10.0)) == []


def test_model_output_is_half_resolution_and_loss_decreases():
    torch.manual_seed(0)
    model = BallNet(pretrained=False)
    image = torch.randn(2, 3, 64, 64)
    target = torch.stack([make_target(64, 64, [(20, 30, 12)]), make_target(64, 64, [])])
    assert model(image).shape == (2, 1, 32, 32)
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
    first = None
    for _ in range(20):
        loss = focal_loss(model(image)[:, 0], target)
        first = first if first is not None else loss.item()
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
    assert loss.item() < first


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("통과:", name)
