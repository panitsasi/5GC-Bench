#!/usr/bin/env python3
import socket
import time
import csv
import os
import random
import json
import argparse
from multiprocessing import Process
from math import isfinite

# ================== Defaults (used unless overridden by CLI) ==================
DESTINATION_IP = "192.168.70.135"
DESTINATION_PORT = 5005
UE_SOURCE_IP = "12.1.1.2"

APP_TRACES = {
    "youtube":   "/gnbsim/bin/youtube_uplink.csv",
    "instagram": "/gnbsim/bin/instagram_uplink.csv",
    "facebook":  "/gnbsim/bin/facebook_uplink.csv",
    "browsing":  "/gnbsim/bin/browsing_uplink.csv",
    "mixed_traffic": "/gnbsim/bin/mixed_traffic_uplink.csv",
}

APP_MIX_DEFAULT = {
    "youtube":   1,
    "instagram": 0,
    "facebook":  0,
    "browsing":  0,
    "mixed_traffic": 0,
}

FLOW_SCHEDULE_CSV_DEFAULT = "/gnbsim/bin/high_load_connections.csv"

FIXED_SLOT_MIN_DEFAULT = 1     # simulate each CSV row 
NUM_DAYS_DEFAULT = 1           # how many days (rows) to take from schedule (1 day = 144 rows)
ROWS_PER_DAY = 144             # fixed: CSV is 10-min cadence → 24h * 6 = 144

BASE_SOURCE_PORT = 25000
MAX_PAYLOAD_BYTES = 1472
USE_STATISTICAL_MULTIPLEXING_DEFAULT = True

# ================== Helpers ==================
def fmt_slot(slot_seconds):
    mins = slot_seconds // 60
    secs = slot_seconds % 60
    return f"{mins} min" if secs == 0 else f"{mins} min {secs}s"

def load_trace(path):
    ts, sz = [], []
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                t = float(row["time"])
                s = int(float(row["packet_length"]))
            except Exception:
                continue
            if not isfinite(t) or not isfinite(s):
                continue
            if s < 1:
                continue
            if s > MAX_PAYLOAD_BYTES:
                s = MAX_PAYLOAD_BYTES
            ts.append(t)
            sz.append(s)
    if not ts:
        raise RuntimeError(f"No valid rows in {path}")
    paired = sorted(zip(ts, sz), key=lambda x: x[0])
    ts_sorted = [t for t, _ in paired]
    sz_sorted = [s for _, s in paired]
    period = ts_sorted[-1] - ts_sorted[0] if len(ts_sorted) > 1 else 0.0
    return ts_sorted, sz_sorted, period

def build_cycle_schedule(timestamps, sizes, start_index):
    """Build (delta_time, size) schedule that loops the trace once."""
    n = len(timestamps)
    base_time = timestamps[start_index]
    rel_times, sizes_for_cycle = [], []
    for offset in range(n):
        i = (start_index + offset) % n
        if i >= start_index:
            t_rel = timestamps[i] - base_time
        else:
            t_rel = (timestamps[i] + (timestamps[-1] - timestamps[0])) - base_time
        rel_times.append(t_rel)
        sizes_for_cycle.append(sizes[i])
    deltas = [0.0] + [rel_times[k] - rel_times[k - 1] for k in range(1, n)]
    return list(zip(deltas, sizes_for_cycle))

def normalize_mix(mix):
    total = sum(max(0.0, float(p)) for p in mix.values())
    if total <= 0:
        raise ValueError("APP_MIX must have positive probabilities.")
    return {k: max(0.0, float(v)) / total for k, v in mix.items()}

def weighted_choice(apps, probs):
    r = random.random()
    cum = 0.0
    for a, p in zip(apps, probs):
        cum += p
        if r <= cum:
            return a
    return apps[-1]

# ================== Flow worker  ==================
def flow_worker(flow_id, start_index, run_seconds, app_name, timestamps, sizes):
    source_port = BASE_SOURCE_PORT + flow_id
    destination = (DESTINATION_IP, DESTINATION_PORT)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((UE_SOURCE_IP, source_port))

    schedule = build_cycle_schedule(timestamps, sizes, start_index)

    start_time = time.time()
    sent = 0
    try:
        while (time.time() - start_time) < run_seconds:
            for delta_time, payload_size in schedule:
                elapsed = time.time() - start_time
                if elapsed >= run_seconds:
                    break
                if delta_time > 0:
                    to_sleep = min(delta_time, max(0.0, run_seconds - elapsed))
                    time.sleep(to_sleep)
                if (time.time() - start_time) >= run_seconds:
                    break
                sock.sendto(b"x" * payload_size, destination)
                sent += 1
    finally:
        try:
            sock.close()
        except Exception:
            pass
        print(f"[FLOW {flow_id}] app={app_name} stopped. Sent {sent} packets.", flush=True)

# ================== Schedule handling  ==================
def load_flow_schedule(schedule_csv, fixed_slot_min, num_days):
    plan = []
    with open(schedule_csv, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        headers = [h.strip().lower() for h in (reader.fieldnames or [])]
        if "duration_min" in headers and "flows" in headers:
            for row in reader:
                try:
                    mins = float(row["duration_min"])
                    flows = int(float(row["flows"]))
                except Exception:
                    continue
                if mins > 0 and flows >= 0:
                    plan.append((int(mins * 60), flows))
        elif "minutes_since_start" in headers and "internet_connections" in headers:
            row_count = 0
            for row in reader:
                if row_count >= num_days * ROWS_PER_DAY:
                    break   # stop after the rows for NUM_DAYS
                try:
                    flows = int(round(float(row["internet_connections"])))
                except Exception:
                    continue
                if flows < 0:
                    flows = 0
                # Each row duration = fixed_slot_min minutes (compressed time)
                plan.append((int(fixed_slot_min * 60), flows))
                row_count += 1
        else:
            raise RuntimeError(
                "Flow schedule CSV must have either [duration_min, flows] or "
                "[minutes_since_start, internet_connections]"
            )
    if not plan:
        raise RuntimeError("Empty or invalid flow schedule.")
    return plan

# ================== Run one slot ==================
def run_slot(slot_seconds, num_flows, traces_by_app, mix_norm, use_stat_mux):
    if num_flows <= 0:
        time.sleep(slot_seconds)
        return

    apps = list(mix_norm.keys())
    probs = [mix_norm[a] for a in apps]
    chosen_apps = [weighted_choice(apps, probs) for _ in range(num_flows)]

    start_indices = []
    for i, app in enumerate(chosen_apps):
        ts, _sz, _period = traces_by_app[app]
        n_rows = len(ts)
        if use_stat_mux:
            idx = int(i * n_rows / max(1, num_flows)) % n_rows
        else:
            idx = 0
        start_indices.append(idx)

    procs = []
    for i in range(num_flows):
        app = chosen_apps[i]
        ts, sz, _ = traces_by_app[app]
        p = Process(target=flow_worker, args=(i, start_indices[i], slot_seconds, app, ts, sz))
        procs.append(p)

    for p in procs:
        p.start()
    for p in procs:
        p.join()

# ================== Argument parsing ==================
def parse_args():
    p = argparse.ArgumentParser(description="Uplink traffic generator with CLI knobs.")
    p.add_argument("--schedule", default=FLOW_SCHEDULE_CSV_DEFAULT,
                   help=f"Path to flow schedule CSV (default: {FLOW_SCHEDULE_CSV_DEFAULT})")
    p.add_argument("--slot-min", type=int, default=FIXED_SLOT_MIN_DEFAULT,
                   help=f"Minutes per slot in simulation (default: {FIXED_SLOT_MIN_DEFAULT})")
    p.add_argument("--days", type=int, default=NUM_DAYS_DEFAULT,
                   help=f"How many days to run (1 day = {ROWS_PER_DAY} rows) (default: {NUM_DAYS_DEFAULT})")
    mux = p.add_mutually_exclusive_group()
    mux.add_argument("--mux", dest="use_mux", action="store_true",
                     help="Enable statistical multiplexing (staggered start indices).")
    mux.add_argument("--no-mux", dest="use_mux", action="store_false",
                     help="Disable statistical multiplexing (all start at index 0).")
    p.set_defaults(use_mux=USE_STATISTICAL_MULTIPLEXING_DEFAULT)
    p.add_argument("--app-mix", type=str, default=None,
                   help=("JSON string for app mix, e.g. "
                         '\'{"youtube":1,"instagram":0,"facebook":0,"browsing":0,"mixed_traffic":0}\'. '
                         "Keys must exist in APP_TRACES."))
    return p.parse_args()

def resolve_app_mix(app_mix_str):
    if not app_mix_str:
        return APP_MIX_DEFAULT
    try:
        mix = json.loads(app_mix_str)
        if not isinstance(mix, dict):
            raise ValueError("app-mix must be a JSON object.")
        # validate keys
        for k in mix.keys():
            if k not in APP_TRACES:
                raise ValueError(f"Unknown app '{k}' (must be one of {list(APP_TRACES.keys())})")
        return mix
    except Exception as e:
        raise SystemExit(f"Failed to parse --app-mix: {e}")

# ================== Main ==================
def main():
    args = parse_args()

    # Resolve knobs
    schedule_csv = args.schedule
    fixed_slot_min = args.slot_min
    num_days = args.days
    use_stat_mux = args.use_mux
    app_mix_input = resolve_app_mix(args.app_mix)

    # Validate traces exist
    for app, path in APP_TRACES.items():
        if not os.path.isfile(path):
            raise FileNotFoundError(f"Trace for app '{app}' not found at {path}")

    # Normalize mix (also checks positivity)
    mix_norm = normalize_mix(app_mix_input)

    # Load all traces once
    traces_by_app = {}
    for app, path in APP_TRACES.items():
        ts, sz, period = load_trace(path)
        traces_by_app[app] = (ts, sz, period)
        print(f"[TRACE] app={app} rows={len(ts)}, period={period:.3f}s, file={os.path.basename(path)}", flush=True)

    # Load flow schedule (compressed by fixed_slot_min and limited by num_days)
    plan = load_flow_schedule(schedule_csv, fixed_slot_min, num_days)
    total_minutes = sum(s // 60 for s, _ in plan)
    mix_str = ", ".join(f"{app}:{mix_norm[app]:.2f}" for app in mix_norm)
    print(f"[SCHEDULE] {len(plan)} slots, total ≈ {total_minutes} minutes", flush=True)
    print(f"[MIX] {mix_str}", flush=True)
    print(f"[MODE] multiplexing={'ON' if use_stat_mux else 'OFF'}", flush=True)

    # Execute plan
    cumulative_sec = 0
    for idx, (slot_seconds, flows) in enumerate(plan, 1):
        start_min = cumulative_sec // 60
        end_min = (cumulative_sec + slot_seconds) // 60
        print(
            f"[SLOT {idx}] window={start_min}–{end_min} min | duration={fmt_slot(slot_seconds)} | flows={flows}",
            flush=True
        )
        run_slot(slot_seconds, flows, traces_by_app, mix_norm, use_stat_mux)
        cumulative_sec += slot_seconds

    print("[MULTI] All slots completed", flush=True)

if __name__ == "__main__":
    main()

