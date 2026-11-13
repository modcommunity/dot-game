#!/usr/bin/env python3
"""Per-system tables of dot-profiler reports side by side.

  dot_game_perf_bench_compare.py REF RUN...            each RUN against REF (the first file)
  dot_game_perf_bench_compare.py --ab A1 B1 A2 B2 ...  group by label (LABEL=path; else A/B by position), mean B-A
  dot_game_perf_bench_compare.py --per-tick RUN...     the per-tick systems in ms per game tick (mean over the runs)
  dot_game_perf_bench_compare.py --check RUN...        only whether each run's world was alive

Every mode flags an INERT run (almost no nodes entering the tree per tick: nothing fought) with a WARN line, prints
INVALID and exits 3; --ab then refuses to rank A against B.

A file is a profiler report (.json) or a log with PERF_BENCH_REPORT / PERF_BENCH_SIDECAR lines.
ms/frame differs with frame rate (2 ticks a frame at 50 ms, fewer on a faster box), so the
per-call column is the one to compare across machines; ms/frame is what a player feels.
"""
import json
import os
import statistics
import sys

# A world where nothing happens (bots never fought, a match never started) adds almost no nodes: ~0.001 a tick, against
# 0.4-1.3 for a live 32-player match. Such a run's ms/tick reads as a speedup it is not (an idle sim-host bench was
# taken for a 20% win for a day). Below this many nodes entering the tree per physics tick, a run is INERT.
INERT_NODES_PER_TICK = float(os.environ.get("PERF_BENCH_INERT_PER_TICK", "0.05"))
# A game that moves its world without making nodes (runners on a trap course, hiders as props) is alive when this many
# Node3D subtrees moved over 1 m in the window (the sidecar's `movers`; older sidecars lack it and judge by nodes alone).
LIVE_MOVERS = int(os.environ.get("PERF_BENCH_LIVE_MOVERS", "3"))


def activity(report, side):
    """(nodes_added, nodes_added per tick, movers or -1) of the measured window, or None when the log carries no node count."""
    side = side or {}
    if "nodes_added" in side:
        return side["nodes_added"], side.get("nodes_added_per_tick", 0.0), side.get("movers", -1)
    eng = report.get("engine") or {}
    if "nodes_added" in eng:
        return eng["nodes_added"], eng.get("nodes_added_per_tick", 0.0), -1
    return None


def inert_note(head):
    """A loud line when the run's world was dead (not a result), else ""."""
    if head["inert"]:
        return "WARN INERT RUN: nodes_added %d (%.3f/tick, limit %.2f), movers %d (live from %d): the world did not play (no fights, no match?); its timings are INVALID, do not rank them" % (
            head["nodes_added"], head["nodes_per_tick"], INERT_NODES_PER_TICK, head["movers"], LIVE_MOVERS)
    return ""


def load(path):
    label = None
    if "=" in path and not path.startswith("/") and path.split("=", 1)[0].isidentifier():
        label, path = path.split("=", 1)
    report = side = None
    with open(path) as f:
        text = f.read()
    if text.lstrip().startswith("{"):
        report = json.loads(text)
    else:
        for line in text.splitlines():
            if line.startswith("PERF_BENCH_REPORT "):
                report = json.loads(line.split(" ", 1)[1])
            elif line.startswith("PERF_BENCH_SIDECAR "):
                side = json.loads(line.split(" ", 1)[1])
    if report is None:
        sys.exit(f"{path}: no report in it")
    frames = max(report.get("frames", 1), 1)
    rows = {}
    for s in report.get("systems", []):
        rows[s["system"]] = {"ms": s["ms"] / frames, "call": s["ms"] / max(s["calls"], 1), "calls": s["calls"] / frames}
    for k, v in report.get("phases", {}).items():
        rows["phase." + k] = {"ms": v / frames, "call": v / frames, "calls": 1}
    # What the engine spends in physics beyond the game's own physics section.
    pre = game_prefix(rows)
    if "phase.physics" in rows and pre + "physics" in rows:
        rest = rows["phase.physics"]["ms"] - rows[pre + "physics"]["ms"]
        rows["engine.physics_outside_game"] = {"ms": rest, "call": rest, "calls": 1}
    if side:
        for k, v in side.get("per_frame", {}).items():
            if k.endswith("_ms"):
                rows["engine." + k] = {"ms": v, "call": v, "calls": 1}
        for k, v in side.get("motor_queries", {}).items():
            rows["query." + k] = {"ms": v["ms_per_frame"], "call": v["us_each"] / 1000.0, "calls": v["per_frame"]}
    act = activity(report, side)
    head = {
        "inert": act is not None and act[1] < INERT_NODES_PER_TICK and act[2] < LIVE_MOVERS,
        "nodes_added": act[0] if act else -1, "nodes_per_tick": act[1] if act else -1.0, "movers": act[2] if act else -1,
        "p50": report.get("p50_ms", 0.0), "p95": report.get("p95_ms", 0.0), "p99": report.get("p99_ms", 0.0),
        "frames": report.get("frames", 0),
        "ticks/frame": rows.get(pre + "physics", {}).get("calls", (side or {}).get("ticks_per_frame", 0.0)),
        "ticks/sec": (side or {}).get("ticks_per_sec", 0.0),
        # Ticks real time asked for and the step cap dropped (older sidecars: from tick_hz and ticks/sec).
        "dropped/sec": (side or {}).get("dropped_per_sec", max((side or {}).get("tick_hz", 0) - (side or {}).get("ticks_per_sec", 0.0), 0.0)),
        "dropped": (side or {}).get("dropped_ticks", -1),
        # The bench's own clock, the same with and without a profiler: {avg, p50, p95, p99, max}.
        "frame_ms": (side or {}).get("frame_ms", {}),
        "profiler": (side or {}).get("profiler", "record"),
        "box": (side or {}).get("adapter") or (side or {}).get("display", "") or "owner",
        # `--first-use 1` rows: [{name, base_ms, worst_ms, over_ms, at, compiles}].
        "first_use": (side or {}).get("first_use", []),
    }
    return label, path, head, rows


def game_prefix(rows):
    """The game's own system prefix ("arena.", "zz."): the one in front of a `physics` system that is not the engine's."""
    for k in rows:
        if k.endswith(".physics") and not k.startswith(("phase.", "engine.")):
            return k[: -len("physics")]
    return "game."


def pct(a, b):
    return (b - a) / a * 100.0 if a > 1e-9 else float("nan")


def order(rows, top):
    keys = sorted(rows, key=lambda k: -rows[k]["ms"])
    keep = [k for k in keys if not k.startswith(("phase.", "engine.", "query."))][:top]
    return keep + sorted(k for k in keys if k.startswith("phase.")) + sorted(k for k in keys if k.startswith(("engine.", "query.")))


def compare(files, top):
    ref = load(files[0])
    runs = [load(f) for f in files[1:]]
    def ticks(h):
        return "ticks/frame %.2f  ticks/sec %.1f  dropped %.1f/s (%d)" % (h["ticks/frame"], h["ticks/sec"], h["dropped/sec"], h["dropped"])

    print("ref %s  p50 %.1f ms  p95 %.1f  p99 %.1f  frames %d  %s" % (ref[1], ref[2]["p50"], ref[2]["p95"], ref[2]["p99"], ref[2]["frames"], ticks(ref[2])))
    for r in runs:
        print("run %s  p50 %.1f ms (%+.0f%%)  p95 %.1f  p99 %.1f  frames %d  %s  [%s]" % (
            r[1], r[2]["p50"], pct(ref[2]["p50"], r[2]["p50"]), r[2]["p95"], r[2]["p99"], r[2]["frames"], ticks(r[2]), r[2]["box"]))
    bad = [r for r in runs if r[2]["inert"]]
    for r in bad:
        print("%s: %s" % (r[1], inert_note(r[2])))
    print()
    print("%-32s %9s %9s" % ("system", "ref ms/f", "ms/call") + "".join(" | %8s %7s %8s %7s" % ("ms/f", "d%", "ms/call", "d%") for _ in runs))
    for k in order(ref[3], top):
        a = ref[3][k]
        line = "%-32s %9.2f %9.4f" % (k, a["ms"], a["call"])
        for r in runs:
            b = r[3].get(k)
            if b is None:
                line += " | %8s %7s %8s %7s" % ("-", "", "-", "")
            else:
                line += " | %8.2f %+6.0f%% %8.4f %+6.0f%%" % (b["ms"], pct(a["ms"], b["ms"]), b["call"], pct(a["call"], b["call"]))
        print(line)
    extra = sorted({k for r in runs for k in r[3]} - set(ref[3]))
    for k in extra:
        line = "%-32s %9s %9s" % (k, "-", "-")
        for r in runs:
            b = r[3].get(k)
            line += " | %8.2f %7s %8.4f %7s" % (b["ms"], "", b["call"], "") if b else " | %8s %7s %8s %7s" % ("-", "", "-", "")
        print(line)
    if bad:
        print()
        print("INVALID: %d of %d run(s) INERT (see WARN above); this table is not a result" % (len(bad), len(runs)))
        return 3
    return 0


def first_use_table(groups):
    """Per first-use name, each label's worst frame (mean and per run) and pipelines compiled: [(label, [head, ...])]."""
    names = []
    for _, heads in groups:
        for h in heads:
            for r in h["first_use"]:
                if r["name"] not in names:
                    names.append(r["name"])
    if not names:
        return
    print()
    print("%-28s" % "first use (worst frame ms)" + "".join(" | %-8s %9s %-24s %8s" % (l, "mean", "runs", "compiles") for l, _ in groups))
    for n in names:
        line = "%-28s" % n
        for _, heads in groups:
            rows = [r for h in heads for r in h["first_use"] if r["name"] == n]
            if not rows:
                line += " | %-8s %9s %-24s %8s" % ("", "-", "", "")
                continue
            line += " | %-8s %9.1f %-24s %8.1f" % ("", statistics.mean(r["worst_ms"] for r in rows),
                " ".join("%.0f" % r["worst_ms"] for r in rows)[:24], statistics.mean(r["compiles"] for r in rows))
        print(line)


def check(files):
    """Only the inert test, for a report-only run (no reference profile): 3 when any file is an inert run."""
    code = 0
    for f in files:
        head = load(f)[2]
        note = inert_note(head)
        if note:
            print("%s: %s" % (f, note))
            code = 3
        elif head["nodes_added"] < 0:
            print("%s: note: no nodes_added in this log (older bench), activity not checked" % f)
        else:
            print("%s: world active (nodes_added %d, %.3f/tick, movers %d)" % (f, head["nodes_added"], head["nodes_per_tick"], head["movers"]))
        if head["first_use"]:
            first_use_table([("run", [head])])
    return code


def ab(files, top):
    groups = {}
    for i, f in enumerate(files):
        label, path, head, rows = load(f)
        groups.setdefault(label or "AB"[i % 2], []).append((head, rows))
        if head["inert"]:
            groups.setdefault("_inert", []).append("%s %s" % (label or "AB"[i % 2], path))
    dead = groups.pop("_inert", [])
    if len(groups) == 2:
        first_use_table([(l, [h for h, _ in g]) for l, g in groups.items()])
    if dead:
        print("WARN INERT RUN(S): the world did not play (nodes_added below %.2f per tick), so their timings say nothing about the code:" % INERT_NODES_PER_TICK)
        for d in dead:
            print("  " + d)
        print("INVALID: not ranking A against B while any run is inert (a dead match reads as a speedup)")
        return 3
    if len(groups) != 2:
        sys.exit("--ab needs exactly two labels")
    (la, ga), (lb, gb) = groups.items()

    def stat(g, key, field="ms"):
        vals = [rows[key][field] for _, rows in g if key in rows]
        return (statistics.mean(vals), min(vals), max(vals)) if vals else None

    pa = [h["p50"] for h, _ in ga]
    pb = [h["p50"] for h, _ in gb]
    print("%s: %d runs, p50 %s ms   %s: %d runs, p50 %s ms   delta %+.2f ms (%+.1f%%)" % (
        la, len(ga), " ".join("%.1f" % v for v in pa), lb, len(gb), " ".join("%.1f" % v for v in pb),
        statistics.mean(pb) - statistics.mean(pa), pct(statistics.mean(pa), statistics.mean(pb))))
    # Sim speed beside the frame: a cheaper tick can buy catch-up ticks instead of a shorter frame, so p50 alone misleads.
    for key in ("ticks/sec", "dropped/sec"):
        va = [h[key] for h, _ in ga]
        vb = [h[key] for h, _ in gb]
        print("%s: %s %s ->  %s: %s %s   delta %+.2f (%+.1f%%)" % (
            la, key, " ".join("%.1f" % v for v in va), lb, key, " ".join("%.1f" % v for v in vb),
            statistics.mean(vb) - statistics.mean(va), pct(statistics.mean(va), statistics.mean(vb))))
    qa = [h["p99"] for h, _ in ga]
    qb = [h["p99"] for h, _ in gb]
    print("%s p99 %s ms   %s p99 %s ms   delta %+.2f ms" % (
        la, " ".join("%.1f" % v for v in qa), lb, " ".join("%.1f" % v for v in qb), statistics.mean(qb) - statistics.mean(qa)))
    # The bench's own frame clock: the measure that holds when one side runs without a profiler.
    if all(h["frame_ms"] for h, _ in ga + gb):
        print("profiler: %s %s, %s %s" % (la, ga[0][0]["profiler"], lb, gb[0][0]["profiler"]))
        for key in ("avg", "p50", "p95", "p99"):
            fa = [h["frame_ms"][key] for h, _ in ga]
            fb = [h["frame_ms"][key] for h, _ in gb]
            noise = "noise" if (min(fb) <= max(fa) and min(fa) <= max(fb)) else ""
            print("bench clock %-4s %s %s ms   %s %s ms   delta %+.3f ms (%+.1f%%)  %s" % (
                key, la, " ".join("%.2f" % v for v in fa), lb, " ".join("%.2f" % v for v in fb),
                statistics.mean(fb) - statistics.mean(fa), pct(statistics.mean(fa), statistics.mean(fb)), noise))
    print()
    print("%-32s %9s %15s %9s %15s %9s %7s  %s" % ("system (ms/frame)", la, "range", lb, "range", "delta", "d%", "noise?"))
    for k in order({**gb[0][1], **ga[0][1]}, top):
        a, b = stat(ga, k), stat(gb, k)
        if a is None or b is None:
            continue
        # A delta inside both runs' spread is not a result.
        noise = "noise" if (b[1] <= a[2] and a[1] <= b[2]) else ""
        print("%-32s %9.2f %7.2f-%-7.2f %9.2f %7.2f-%-7.2f %+9.2f %+6.1f%%  %s" % (k, a[0], a[1], a[2], b[0], b[1], b[2], b[0] - a[0], pct(a[0], b[0]), noise))
    # A cheaper tick can buy more catch-up ticks a frame instead of a shorter frame (a tick budget),
    # so the per-call cost of the per-tick systems is the direct measure of a sim change.
    print()
    print("%-32s %9s %15s %9s %15s %9s %7s  %s" % ("per call (ms) / ticks", la, "range", lb, "range", "delta", "d%", "noise?"))
    pre = game_prefix(ga[0][1])
    for k in [pre + n for n in ["physics", "game_tick", "tick_players", "p_controller", "p_weapons",
                                "p_hulls", "bots", "bot_brain", "tick_world",
                                "pl_pre", "pl_sim", "pl_post", "p_pre", "p_hitbox", "p_wctx"]]:
        a, b = stat(ga, k, "call"), stat(gb, k, "call")
        if a is None or b is None:
            continue
        noise = "noise" if (b[1] <= a[2] and a[1] <= b[2]) else ""
        print("%-32s %9.4f %7.4f-%-7.4f %9.4f %7.4f-%-7.4f %+9.4f %+6.1f%%  %s" % (k, a[0], a[1], a[2], b[0], b[1], b[2], b[0] - a[0], pct(a[0], b[0]), noise))
    ta = [h["ticks/frame"] for h, _ in ga]
    tb = [h["ticks/frame"] for h, _ in gb]
    print("%-32s %9.2f %15s %9.2f" % ("ticks/frame", statistics.mean(ta), "", statistics.mean(tb)))
    # Simulated ticks per wall second: the game's speed (66 is real time).
    sa = [h["ticks/sec"] for h, _ in ga]
    sb = [h["ticks/sec"] for h, _ in gb]
    print("%-32s %9.2f %15s %9.2f" % ("ticks/sec (sim speed)", statistics.mean(sa), "", statistics.mean(sb)))
    da = [h["dropped/sec"] for h, _ in ga]
    db = [h["dropped/sec"] for h, _ in gb]
    print("%-32s %9.2f %15s %9.2f" % ("dropped ticks/sec", statistics.mean(da), "", statistics.mean(db)))
    return 0


def per_tick(files, top):
    runs = [load(f) for f in files]
    for r in runs:
        if r[2]["inert"]:
            print("%s: %s" % (r[1], inert_note(r[2])))
    heads = [r[2] for r in runs]
    print("%d run(s)  p50 %s ms  p99 %s  ticks/frame %s  ticks/sec %s  dropped/sec %s" % (
        len(runs), " ".join("%.1f" % h["p50"] for h in heads), " ".join("%.1f" % h["p99"] for h in heads),
        " ".join("%.2f" % h["ticks/frame"] for h in heads), " ".join("%.1f" % h["ticks/sec"] for h in heads),
        " ".join("%.1f" % h["dropped/sec"] for h in heads)))
    print("%-32s %10s %10s %9s" % ("system", "ms/tick", "us/call", "calls/tick"))
    pre = game_prefix(runs[0][3])
    keys = [k for k in order(runs[0][3], top) if k.startswith(pre) or k.startswith("query.")]
    for k in keys:
        vals = [(r[3][k]["ms"] / max(r[2]["ticks/frame"], 1e-9), r[3][k]["call"] * 1000.0, r[3][k]["calls"] / max(r[2]["ticks/frame"], 1e-9))
                for r in runs if k in r[3]]
        if not vals:
            continue
        print("%-32s %10.3f %10.1f %9.1f" % (k, statistics.mean(v[0] for v in vals), statistics.mean(v[1] for v in vals), statistics.mean(v[2] for v in vals)))
    if any(r[2]["inert"] for r in runs):
        print("INVALID: inert run(s) above")
        return 3
    return 0


def main():
    args = sys.argv[1:]
    top = 40
    if "--top" in args:
        i = args.index("--top")
        top = int(args[i + 1])
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    if args[0] == "--ab":
        code = ab(args[1:], top)
    elif args[0] == "--per-tick":
        code = per_tick(args[1:], top)
    elif args[0] == "--check":
        code = check(args[1:])
    else:
        code = compare(args, top)
    sys.exit(code)


if __name__ == "__main__":
    main()
