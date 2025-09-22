# 5GC-Bench

This README guides you through reproducing the **5GC-Bench** experiments to stress-test 5G Core (5GC) VNFs using OpenAirInterface (OAI) and gNBSIM. It covers environment setup, core deployment, telemetry collection, and how to run control-plane service chains and user-plane workloads.

> **Tested on:** Ubuntu 22.04, Docker 27.5.0, Docker Compose v2, Python 3.10+.  
> **Core:** OAI CN5G v2.1.0  
> **Access side:** gNBSIM (UE/RAN simulator)

---

## 0) Prerequisites

- **Docker** and **Docker Compose v2** (e.g., `docker compose version` works)
- **Python 3.10+** with `pip`
- `git`, `curl`, and basic build tools
- Sudo access (for Docker)

Quick sanity checks:
```bash
docker --version
docker compose version
python3 --version
```

---

## 1) Clone the OAI 5GC repo and 5GC-Bench

```bash
cd ~
git clone https://gitlab.eurecom.fr/oai/cn5g/oai-cn5g-fed.git
cd ~
git clone https://github.com/panitsasi/5GC-Bench.git

```

---

## 2) Override compose files

Copy the **override** files from this repo into the OAI compose folder.

```bash
cp code/docker/docker-compose-mini-nonrf.yaml         ~/oai-cn5g-fed/docker-compose/
cp code/docker/docker-compose-gnbsim.yaml             ~/oai-cn5g-fed/docker-compose/
cp code/docker/docker-compose-basic-vpp-nrf.yaml      ~/oai-cn5g-fed/docker-compose/
```

---

## 3) Pull and tag gNBSIM image

```bash
docker pull rohankharade/5gc-gnbsim:0.0.1-dev
docker tag  rohankharade/5gc-gnbsim:0.0.1-dev  5gc-gnbsim:0.0.1-dev
```
---

## 4) Build the images

```bash
# Copy the updated Dockerfiles
cp ~/code/docker/Dockerfile.ubuntu.22.04_updated ~/gnbsim/docker/Dockerfile.ubuntu.22.04_updated
cp ~/code/docker/Dockerfile.traffic.generator.ubuntu_updated ~/oai-cn5g-fed/ci-scripts/Dockerfile.traffic.generator.ubuntu_updated

# Build the updated images
cd ~/gnbsim
docker build --tag gnbsim_updated:latest --target gnbsim --file docker/Dockerfile.ubuntu.22.04_updated .

cd ~/oai-cn5g-fed/
docker build --target trf-gen-cn5g --tag trf-gen-cn5g-updated:latest --file ci-scripts/Dockerfile.traffic.generator.ubuntu_updated ci-scripts

```
---

## 4) Fetch the user plane traffic traces

```bash

# Move all user plane CSV traces from 5GC_Bench/data into ~/gnbsim and ci-scripts folder
mv ~/5GC_Bench/data/*.csv ~/gnbsim/
mv ~/5GC_Bench/data/*.csv ~/oai-cn5g-fed/ci-scripts/
# Move the gnbsim client and server scripts into ~/gnbsim and rename them
mv ~/5GC_Bench/code/user_plane/gnbsim_client.py ~/gnbsim/client.py
mv ~/5GC_Bench/code/user_plane/gnbsim_server.py ~/gnbsim/server.py
# Move the traffic_dn_client and server scripts into ~/oai-cn5g-fed/ci-scripts and rename them
mv ~/5GC_Bench/code/user_plane/traffic_dn_client.py ~/oai-cn5g-fed/ci-scripts/client.py
mv ~/5GC_Bench/code/user_plane/traffic_dn_server.py ~/oai-cn5g-fed/ci-scripts/server.py

```
---

## 5) Deploy the OAI 5G Core 

```bash
cd ~/oai-cn5g-fed/docker-compose
python3 ./core-network.py --type start-basic-vpp --scenario 1
```

- **Wait ~20 seconds** for VNFs to become healthy.

> If something fails to start, run `docker compose ls` and `docker logs <container>` to diagnose. Ensure no port conflicts and that previous runs are fully stopped.

---

## 6) Start the Telemetry Collector

From the **5GC-Bench** repo:

```bash
cd ~/code/control_plane/
python3 collect_metrics_core.py
```

- Collects Docker-level metrics at **1s granularity** for AMF, SMF, NRF, AUSF, UDM, UDR, UPF, etc.
- Outputs **analysis-ready CSVs** aligned to experiment timestamps.

> Keep this running in a separate terminal while you execute scenarios below.

---

## 7) Launch gNBSIM

Use the pre-configured compose file:

```bash
cd ~/oai-cn5g-fed/docker-compose
docker compose -f docker-compose-omec-gnbsim-vpp.yaml up -d
```

- **Important:** Starting gNBSIM will immediately execute **the scenario specified** in your `omec-gnbsim-config.yaml`. **Review/edit that config before starting** to ensure you run the intended procedure and UE load.

---

## 8) Add subscribers (optional, for large scale experiments)

You can quickly provision many UEs in the 5G Core using the helper script:

```bash
cd ~/code/control_plane
./add_subscribers.sh 208950000000132 100
```

- The example above adds **100** subscribers starting at IMSI `208950000000132`, incrementing by 1.
- Adjust the **starting IMSI** and **count** as needed.

> Re-run with different ranges to build large pools for stress tests.

---

## 9) Control-Plane VNF Micro-Benchmarks (Targeted)

Before running full service chains, you can **stress individual control-plane VNFs** with the helper scripts in `code/control_plane/`. Example (AUSF authentication vector generation):

```bash
cd ~/code/control_plane
./ausf_generate_auth.sh 200 --mode par --concurrency 8
```

- `200`: total HTTP requests to issue  
- `--mode par`: parallel mode 
- `--concurrency 8`: number of workers/threads

Other available scripts (examples; names may vary by release):
```bash
./nrf_discovery_requests.sh 300 --mode par --concurrency 16   # Stress NRF discovery
./udm_get_auth_sub.sh 200 --mode par --concurrency 8          # Query UDM for auth/subscription
./nrf_register_vnfs.sh 50 --mode par --concurrency 4          # Re/registration bursts to NRF
```
> More scripts will be released shortly. Check `code/control_plane/` for the latest set and usage.

---

## 10) Control-Plane Experiments (Service Chains)

For service chain stressing, we used gNBSIM, a UE/RAN emulator that includes standards-compliant procedures and can be driven at configurable rates and numbers of users. The following components are integrated with OAI and have been validated:

1. **Registration**  
2. **UE-initiated PDU Session Establishment**  
3. **UE-initiated De-registration**

### 10.1 Configure procedure & load

Edit `omec-gnbsim-config.yaml` to set:
- **Procedure** (registration / session establish / de-registration)  
- **Number of UEs** (e.g., 100, 200, 500)  
- **Arrival pattern** (sequential, bursty) and timing knobs (inter-arrival, bursts, duration)

> **Note:** As soon as you (re)start gNBSIM, it will execute whatever is configured here.

### 10.2 Run the scenario

```bash
# Apply your desired gNBSIM config (already mounted via compose)
cd ~/oai-cn5g-fed/docker-compose
docker compose -f docker-compose-omec-gnbsim-vpp.yaml up -d 
```

- Tail core VNFs to observe chain behavior:
  ```bash
  docker logs -f oai-amf   # and/or oai-smf, oai-udm, oai-ausf, oai-nrf
  ```
- Collect telemetry CSVs while the scenario runs; stop gNBSIM when finished (see §11).

---

## 11) User-Plane Experiments (UPF stress / realistic traffic)

After establishing PDU sessions (e.g., via §9), you can stress the **UPF** with synthetic or trace-driven traffic. Keep the telemetry collector running.

- **Synthetic sanity check:** run `iperf3` server in the DN and clients from UEs.  
- **Trace-driven:** use the UPLI helpers in `code/user_plane/` to replay **YouTube/Instagram/Browsing/Gaming** or mixed profiles derived from TelecomTS/NetMob.

Examples:
```bash
# 1. Terminate the gnbsim and the core network
cd ~/oai-cn5g-fed/docker-compose
docker-compose -f docker-compose-gnbsim.yaml down -t 0
python3 ./core-network.py --type stop-basic-vpp --scenario 1

# 2. Start minimalist core (UPF + DN + helpers only)
docker compose -f docker-compose-mini-nonrf.yaml up -d

# 3. Launch gnbsim with trace-driven traffic
docker compose -f docker-compose-gnbsim.yaml up -d gnbsim

# 4. Synthetic: DN-side iperf3 server
docker exec -it oai-ext-dn iperf3 -s

# 5. Trace-driven: per-UE replay (uplink)
docker exec -it gnbsim python3 client.py \
  --schedule /gnbsim/bin/high_load_connections.csv \
  --slot-min 1 --days 1 --mux \
  --app-mix '{"youtube":1,"instagram":0,"facebook":0,"browsing":0,"mixed_traffic":0}'

docker exec -it gnbsim python3 server.py

# 6. Trace-driven: DN replay (downlink)
docker exec -it oai-ext-dn python3 client.py \
  --schedule /tmp/high_load_connections.csv \
  --slot-min 1 --days 1 --mux \
  --app-mix '{"youtube":1,"instagram":0,"facebook":0,"browsing":0,"mixed_traffic":0}'

docker exec -it oai-ext-dn python3 server.py
```

---

## 12) Stopping & Cleanup

Stop **gNBSIM** (choose the file you used):
```bash
# If you used the 'omec' variant during start:
docker compose -f docker-compose-omec-gnbsim-vpp.yaml down -t 0
```

Stop the **Core**:
```bash
python3 ./core-network.py --type stop-basic-vpp --scenario 1
```

---

## Data

If you plan to use this setup, please send an email to **ioannis.panitsas@yale.edu** to receive the user-plane data and traffic traces.

## Citation

If you use this setup, please cite our paper **5GC-Bench: A Framework for Stress-Testing and Benchmarking 5G Core VNFs**.
