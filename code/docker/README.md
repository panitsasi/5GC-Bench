# gNBSIM & Traffic Generator with OAI 5G Core

This README provides step-by-step instructions to build the Docker images, start the OAI 5G Core Network with gNBSIM, and stop the services cleanly.

---

## 🛠 Usage Instructions

```bash
# ==============================
# 📦 Build Docker Images
# ==============================

# Build gNBSIM Image
cd ~/gnbsim
docker build \
  --tag gnbsim_updated:latest \
  --target gnbsim \
  --file docker/Dockerfile.ubuntu.22.04_updated .

# Build Traffic Generator Image
cd ~/oai-cn5g-fed/
docker build \
  --target trf-gen-cn5g \
  --tag trf-gen-cn5g-updated:latest \
  --file ci-scripts/Dockerfile.traffic.generator.ubuntu_updated ci-scripts


# ==============================
# 🚀 Start 5G Core and gNBSIM
# ==============================

# Start OAI 5G Core Network (non-NRF mode)
cd ~/oai-cn5g-fed/docker-compose
docker compose -f docker-compose-mini-nonrf.yaml up -d

# Start gNBSIM
docker-compose -f docker-compose-gnbsim.yaml up -d gnbsim


# ==============================
# 🛑 Stop 5G Core and gNBSIM
# ==============================

# Stop gNBSIM
docker-compose -f docker-compose-gnbsim.yaml down -t 0

# Stop OAI 5G Core Network
docker compose -f docker-compose-mini-nonrf.yaml down


# ==============================
# ✅ Notes
# ==============================

# Ensure Docker and Docker Compose v2 are installed and running.
# Repository structure assumed:
#   ~/gnbsim
#   ~/oai-cn5g-fed/
#
# Check logs of a container:
#   docker logs <container_name>
#
# List running containers:
#   docker ps
