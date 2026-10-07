"""Before/after quota measurement: how many weekly points one 5h point costs.

  quota_mark.py set [--tool claude]   record a marker at the latest sample
  quota_mark.py [--tool claude]       report everything logged since the marker

Reads quota-<tool>.log from GAZE_QUOTA_DIR (default %LOCALAPPDATA%/gaze) and
keeps the marker beside it as quota-mark-<tool>.tsv. Works for any tool whose
log has 5h= and 7d= fields (claude, codex).

The weekly meter is whole points, so the precise figure is tick-to-tick: 5h
points counted only between the first and last weekly increment after the
marker, which removes the weekly rounding. Stale samples (an idle session
re-reporting old values) are ignored by tracking running maxima per window.
"""
import datetime as dt
import os
import sys
import time

BIN = 240  # reset stamps jitter by seconds; the same window is within this


def state_dir():
    return os.environ.get("GAZE_QUOTA_DIR") or os.path.join(os.environ["LOCALAPPDATA"], "gaze")


def samples(log, since=0):
    for line in open(log, encoding="ascii", errors="replace"):
        p = line.split()
        f = dict(kv.split("=", 1) for kv in p[1:] if "=" in kv)
        if "5h" not in f or "7d" not in f or int(p[0]) < since:
            continue
        s, sr = map(int, f["5h"].split("@"))
        w, wr = map(int, f["7d"].split("@"))
        yield int(p[0]), s, sr, w, wr


def fmt(t):
    return dt.datetime.fromtimestamp(t).strftime("%a %m-%d %H:%M:%S")


def main(argv):
    tool = "claude"
    if "--tool" in argv:
        i = argv.index("--tool")
        tool = argv[i + 1]
        del argv[i:i + 2]
    log = os.path.join(state_dir(), f"quota-{tool}.log")
    mark = os.path.join(state_dir(), f"quota-mark-{tool}.tsv")

    if argv == ["set"]:
        rows = list(samples(log))
        if not rows:
            sys.exit(f"no 5h/7d samples in {log}")
        _, s, sr, w, wr = rows[-1]
        now = int(time.time())
        with open(mark, "w", encoding="ascii", newline="\n") as fh:
            fh.write(f"{now}\t{s}\t{sr}\t{w}\t{wr}\n")
        print(f"{tool} marker set {fmt(now)}: 5h={s}% weekly={w}% (5h resets {fmt(sr)})")
        return
    if argv:
        sys.exit(__doc__)
    if not os.path.exists(mark):
        sys.exit(f"no marker for {tool}: run with 'set' first")

    mt, ms, msr, mw, mwr = map(int, open(mark).read().split())
    print(f"{tool} marker {fmt(mt)}: 5h={ms}% weekly={mw}%")
    # Walk samples in the marker's weekly window. 5h points accumulate across
    # 5h resets; within a window only the running max counts.
    points = []  # (t, 5h points since marker, weekly max)
    done, base, top5, topw, cur = 0, ms, ms, mw, msr
    for t, s, sr, w, wr in samples(log, mt):
        if abs(wr - mwr) >= BIN:
            continue
        if abs(sr - cur) >= BIN:
            if sr < cur:
                continue  # stale sample from an earlier window
            done += top5 - base
            base, top5, cur = 0, 0, sr
        top5, topw = max(top5, s), max(topw, w)
        points.append((t, done + top5 - base, topw))
    if not points:
        print("no samples since marker")
        return

    t, d5, wk = points[-1]
    dw = wk - mw
    print(f"now    {fmt(t)}: +{d5} 5h points, weekly {mw}->{wk} (+{dw})")
    if d5:
        print(f"naive        {dw / d5:.4f} weekly per 5h point  (+-1 weekly point of rounding on +{dw})")
    ticks = [b for i, b in enumerate(points) if i and b[2] > points[i - 1][2]]
    if len(ticks) < 2:
        print(f"tick-to-tick needs 2 weekly increments, have {len(ticks)}")
        return
    a, z = ticks[0], ticks[-1]
    n, p = z[2] - a[2], z[1] - a[1]
    if p:
        print(f"tick-to-tick {n / p:.4f} weekly per 5h point  ({n} weekly over {p} 5h points, +-{n / p / p:.4f})")
        print(f"             a full 5h window = {100 * n / p:.1f}% weekly, {p / n:.1f} windows per week")


if __name__ == "__main__":
    main(sys.argv[1:])
