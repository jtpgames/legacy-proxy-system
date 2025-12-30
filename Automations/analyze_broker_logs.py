#!/usr/bin/env python3

import sys
from datetime import datetime
from math import sqrt
from statistics import mean, pstdev

try:
    from scipy.stats import kstest, expon
    SCIPY_AVAILABLE = True
except ImportError:
    SCIPY_AVAILABLE = False


def parse_times(stream):
    in_times = []
    out_times = []

    counter = 0
    count = 0

    print("begin parsing")

    for line in stream:
        if '[INBOUND]' in line or '[OUTBOUND]' in line:
            ts = line[:23]  # YYYY-MM-DD HH:MM:SS,mmm
            t = datetime.strptime(ts, "%Y-%m-%d %H:%M:%S,%f")

            if '[INBOUND]' in line:
                in_times.append(t)
            else:
                out_times.append(t)
        counter += 1
        if counter >= 20000:
            count += counter
            print(f"parsed {count} lines")
            counter = 0

    return sorted(in_times), sorted(out_times)


def rate(times):
    if len(times) < 2:
        return 0.0
    duration = (times[-1] - times[0]).total_seconds()
    return len(times) / duration if duration > 0 else 0.0


def inter_event_times(times):
    return [
        (t2 - t1).total_seconds()
        for t1, t2 in zip(times, times[1:])
        if (t2 - t1).total_seconds() > 0
    ]


def summarize_intervals(name, intervals, rate_est):
    if not intervals:
        print(f"{name}: insufficient data")
        return

    m = mean(intervals)
    sd = pstdev(intervals)
    cv = sd / m if m > 0 else float('nan')

    print(f"{name}:")
    print(f"  mean interval      = {m:.6f} s")
    print(f"  std deviation      = {sd:.6f} s")
    print(f"  coefficient of var = {cv:.3f}")

    if SCIPY_AVAILABLE:
        D, p = kstest(intervals, expon(scale=1 / rate_est).cdf)
        print(f"  KS test D          = {D:.4f}")
        print(f"  KS test p-value    = {p:.4f}")
    else:
        print("  KS test            = scipy not available")


def main():
    in_times, out_times = parse_times(sys.stdin)

    lam = rate(in_times)
    mu = rate(out_times)

    print("=== Rate Estimates ===")
    print(f"Arrival rate λ = {lam:.4f} msg/s")
    print(f"Service rate μ = {mu:.4f} msg/s")

    if mu > 0:
        rho = lam / mu
        print(f"Utilization ρ  = {rho:.4f}")
    else:
        print("Utilization ρ  = undefined")

    print("\n=== M/M/1 Validation ===")

    ia = inter_event_times(in_times)
    idp = inter_event_times(out_times)

    summarize_intervals("Inter-arrival times", ia, lam)
    summarize_intervals("Inter-departure times", idp, mu)


if __name__ == "__main__":
    main()

