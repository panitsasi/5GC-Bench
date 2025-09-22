#!/usr/bin/env python3
import csv
import os
import re
import subprocess
import time
from datetime import datetime

containers = ["oai-udr","oai-ausf","oai-amf","oai-udm","oai-smf","oai-nrf", "oai-upf"]
output_file = "oai_core_stats.csv"

ansi_re = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")  # strip ANSI escapes

with open(output_file, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["timestamp", "container", "cpu_percent", "mem_percent"])

    # streaming docker stats; TERM=dumb helps suppress TTY control codes
    env = dict(os.environ)
    env["TERM"] = "dumb"

    cmd = ["docker", "stats", "--format", "{{.Name}},{{.CPUPerc}},{{.MemPerc}}"] + containers
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True, bufsize=1, env=env)

    try:
        expected = len(containers)
        batch = {}
        last_write = 0.0

        for line in proc.stdout:
            line = ansi_re.sub("", line.strip())
            if not line:
                continue

            parts = line.split(",")
            if len(parts) != 3:
                continue

            name, cpu, mem = parts
            cpu = cpu.strip().rstrip("%")
            mem = mem.strip().rstrip("%")
            batch[name] = (cpu, mem)

            # When we have all containers, write one row per container with same timestamp
            if len(batch) == expected:
                now = time.perf_counter()
                # enforce ~1s cadence: if the last batch was <0.9s ago, drop this one
                if (now - last_write) >= 0.9:
                    ts = datetime.now().isoformat(timespec="seconds")
                    for cname in containers:
                        if cname in batch:
                            c_cpu, c_mem = batch[cname]
                            w.writerow([ts, cname, c_cpu, c_mem])
                    f.flush()
                    last_write = now
                batch.clear()

    except KeyboardInterrupt:
        print(f"\n[INFO] Stopped. Data saved in {output_file}")
    finally:
        try:
            proc.terminate()
        except Exception:
            pass
