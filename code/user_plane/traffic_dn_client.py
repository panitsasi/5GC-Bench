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
UE_DESTINATION_IP = "12.1.1.2"          # UE IP (gnbsim)
UE_DESTINATION_PORT = 5005
DN_SOURCE_IP = "192.168.70.135"         # oai-ext-dn IP

# ---- Downlink app traces  ----
APP_TRACES_DL = {
    "youtube":   "/tmp/youtube_downlink.csv",
    "instagram": "/tmp/instagram_downlink.csv",
    "facebook":  "/tmp/facebook_downlink.csv",
    "browsing":  "/tmp/browsing_downlink.csv",
    "mixed_traffic": "/tmp/mixed_traffic_downlink.csv",
}

# ---- App mix (probabilities) ----
APP_MIX_DL_DEFAULT = {
    "youtube":   1.0,
    "instagram": 0,
    "facebook":  0,
    "browsing":  0,
    "mixed_traffic": 0,
}

# ---- Flow schedule CSV ----
FLOW_SCHEDULE_CSV_DEFAULT = "/tmp/high_load_connections.csv"

# ---- Time configuration ----
FIXED_SLOT_MIN_DEFAULT = 1    # simulate each CSV row as this many minutes (instead of 10 real minutes)
NUM_DAYS_DEFAULT = 1          # how many days to run
ROWS_PER_DAY = 144            # fixed: 1 day = 144 rows (24h / 10min slots)

# ---- Replay configuration ----
BASE_SOURCE_PORT = 50000                # flow i uses DN_SOURCE_IP:(BASE_SOURCE_PORT + i)
MAX_PAYLOAD_BYTES = 1472                # 1472 avoids fragmentation under 1500B MTU
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
    n = len(timestamps)
    base_time = timestamps[start_index]
    rel = []
    sizes_for_cycle = []
    for off in range(n):
        i = (start_index + off) % n
        if i >= start_index:
            t_rel = timestamps[i] - base_time
        else:
            t_rel = (timestamps[i] + (timestamps[-1] - timestamps[0])) - base_time
        rel.append(t_rel)
        sizes_for_cycle.append(sizes[i])
    deltas = [0.0] + [rel[k] - rel[k-1] for k in range(1, n)]
    return list(zip(deltas, sizes_for_cycle))

def normalize_mix(mix):
    total = sum(max(0.0, float(p)) for p in mix.values())
    if total <= 0:
        raise ValueError("APP_MIX_DL must have positive probabilities.")
    return {k: max(0.0, float(v)) / total for k, v in mix.items()}

def weighted_choice(apps, probs):
    r, cum = random.random(), 0.0
    for a, p in zip(apps, probs):
        cum += p
        if r <= cum:
            return a
    return apps[-1]

# ================== Flow worker ==================
def flow_worker(flow_id, start_index, run_seconds, app_name, timestamps, sizes):
    source_port = BASE_SOURCE_PORT + flow_id
    destination = (UE_DESTINATION_IP, UE_DESTINATION_PORT)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((DN_SOURCE_IP, source_port))

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
        print(f"[DL FLOW {flow_id}] app={app_name} stopped. Sent {sent} packets.", flush=True)

# ================== Schedule ==================
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
                    break  # only take rows for the requested number of days
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
        ts, _sz, _ = traces_by_app[app]
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
    p = argparse.ArgumentParser(description="Downlink traffic generator with CLI knobs.")
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
                         "Keys must exist in APP_TRACES_DL."))
    return p.parse_args()

def resolve_app_mix(app_mix_str):
    if not app_mix_str:
        return APP_MIX_DL_DEFAULT
    try:
        mix = json.loads(app_mix_str)
        if not isinstance(mix, dict):
            raise ValueError("app-mix must be a JSON object.")
        for k in mix.keys():
            if k not in APP_TRACES_DL:
                raise ValueError(f"Unknown app '{k}' (must be one of {list(APP_TRACES_DL.keys())})")
        return mix
    except Exception as e:
        raise SystemExit(f"Failed to parse --app-mix: {e}")

# ================== Main ==================
def main():
    args = parse_args()

    schedule_csv  = args.schedule
    fixed_slot_min = args.slot_min
    num_days       = args.days
    use_stat_mux   = args.use_mux
    app_mix_input  = resolve_app_mix(args.app_mix)

    # Normalize mix and load traces
    mix_norm = normalize_mix(app_mix_input)

    traces_by_app = {}
    for app, path in APP_TRACES_DL.items():
        if not os.path.isfile(path):
            raise FileNotFoundError(f"Downlink trace for '{app}' not found at {path}")
        ts, sz, period = load_trace(path)
        traces_by_app[app] = (ts, sz, period)
        print(f"[DL TRACE] app={app} rows={len(ts)}, period={period:.3f}s, file={os.path.basename(path)}", flush=True)

    # Load schedule (compressed and day-limited)
    plan = load_flow_schedule(schedule_csv, fixed_slot_min, num_days)
    total_minutes = sum(s // 60 for s, _ in plan)
    mix_str = ", ".join(f"{a}:{mix_norm[a]:.2f}" for a in mix_norm)
    print(f"[DL SCHEDULE] {len(plan)} slots, total ≈ {total_minutes} minutes", flush=True)
    print(f"[DL MIX] {mix_str}", flush=True)
    print(f"[DL MODE] multiplexing={'ON' if use_stat_mux else 'OFF'}", flush=True)

    # Execute slots
    cumulative_sec = 0
    for idx, (slot_seconds, flows) in enumerate(plan, 1):
        start_min = cumulative_sec // 60
        end_min = (cumulative_sec + slot_seconds) // 60
        print(f"[DL SLOT {idx}] window={start_min}–{end_min} min | duration={fmt_slot(slot_seconds)} | flows={flows}", flush=True)
        run_slot(slot_seconds, flows, traces_by_app, mix_norm, use_stat_mux)
        cumulative_sec += slot_seconds

    print("[DL MULTI] All slots completed", flush=True)

if __name__ == "__main__":
    main()
