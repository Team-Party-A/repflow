"""Reference replay for the Swift dumbbell curl counter."""

import math
from collections import deque

from inspect_recording import VECTOR_FIELDS

WINDOW_SECONDS = 0.20
MAXIMUM_GAP = 0.20
MINIMUM_INTERVAL = 0.90
QUIET_RATE = 0.20
MINIMUM_PEAK_RATE = 1.50
MINIMUM_LIFT = 0.45
RETURN_FRACTION = 0.85
ASSISTED_RETURN_FRACTION = 0.70
MINIMUM_GRAVITY_COSINE = 0.90


def _gravity_at_start(gravity, start):
    length_product = math.sqrt(sum(v * v for v in gravity)) * math.sqrt(
        sum(v * v for v in start)
    )
    if length_product <= 0 or not math.isfinite(length_product):
        return False
    dot = sum(v * initial for v, initial in zip(gravity, start))
    return dot / length_product >= MINIMUM_GRAVITY_COSINE


def replay_curl(samples):
    """Yield (count, gap count) after each sample from a single set."""
    count = gaps = 0
    phase = "waiting_for_quiet"
    window = deque()
    rate_sum = 0.0
    previous = last_count_time = None
    start_gravity = None
    angle = highest_angle = 0.0
    reached_peak = False

    for sample in samples:
        timestamp = sample["t_s"]
        if (
            not math.isfinite(timestamp)
            or timestamp < 0
            or (previous is not None and timestamp <= previous["t_s"])
            or not all(
                math.isfinite(v) for field in VECTOR_FIELDS for v in sample[field]
            )
        ):
            yield count, gaps
            continue

        interval = timestamp - previous["t_s"] if previous is not None else 0.0
        if interval > MAXIMUM_GAP:
            gaps += 1
            phase = "waiting_for_quiet"
            window.clear()
            rate_sum = 0.0

        rate = -sample["rotation_rate_rad_s"][1]
        window.append((timestamp, rate))
        rate_sum += rate
        while window[0][0] < timestamp - WINDOW_SECONDS:
            rate_sum -= window.popleft()[1]
        smooth_rate = rate_sum / len(window)
        prior = previous
        previous = sample

        if phase == "waiting_for_quiet":
            if abs(smooth_rate) <= QUIET_RATE:
                phase = "ready"
            yield count, gaps
            continue
        if phase == "ready":
            if smooth_rate <= QUIET_RATE:
                yield count, gaps
                continue
            start_gravity = prior["gravity_g"]
            angle = highest_angle = 0.0
            reached_peak = False
            phase = "moving"

        angle += smooth_rate * interval
        highest_angle = max(highest_angle, angle)
        reached_peak = reached_peak or smooth_rate >= MINIMUM_PEAK_RATE
        if not reached_peak or highest_angle < MINIMUM_LIFT:
            if angle <= 0:
                phase = "ready"
        elif smooth_rate < 0:
            returned = highest_angle - angle
            gravity_confirms_return = (
                returned >= ASSISTED_RETURN_FRACTION * highest_angle
                and _gravity_at_start(sample["gravity_g"], start_gravity)
            )
            if returned >= RETURN_FRACTION * highest_angle or gravity_confirms_return:
                phase = "ready"
                if (
                    last_count_time is None
                    or timestamp - last_count_time >= MINIMUM_INTERVAL
                ):
                    count += 1
                    last_count_time = timestamp
        yield count, gaps
