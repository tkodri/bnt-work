#!/bin/bash
# ============================================================
#  BNT Work Setup — one-liner Blocknet worker deploy
#  Usage:  curl -sL https://raw.githubusercontent.com/tkodri/bnt-work/main/setup.sh | bash -s <worker_name> [threads]
#  Example: curl -sL https://raw.githubusercontent.com/tkodri/bnt-work/main/setup.sh | bash -s vps1
#
#  No private keys needed. Public address only.
#  Coexists with GPU workloads (nice=19, idle IO).
# ============================================================
set -e

WORKER="${1:-$(hostname)}"
ADDR="9eQxRUhiGUQszhnq58omrQHyfhbsSq2hjbhgoCk5gqp7LcCwVvTxYbvpRJvdJQkCzx5WUrkNNHb4MqjZ1hWna74PUpbFg"
THREADS="${2:-$(nproc)}"
POOL="stratum+tcp://bntpool.com:3333"
BASE="/opt/blocknet"
WORK="$BASE/work"

echo "[*] Worker: $WORKER | Threads: $THREADS | Pool: $POOL"
echo "[*] Address: ${ADDR:0:10}...${ADDR: -6}"

# --- deps ---
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq curl python3 2>/dev/null || true

mkdir -p "$WORK"
cd "$BASE"

# --- 1. CLI manager ---
if [ ! -x "$BASE/blocknet" ]; then
    echo "[*] Downloading CLI manager..."
    curl -sL "https://github.com/blocknetprivacy/blocknet/releases/download/v1.2.0/blocknet-amd64-linux.zip" -o /tmp/bnt-cli.zip
    python3 -c "import zipfile; zipfile.ZipFile('/tmp/bnt-cli.zip').extractall('$BASE')"
    rm -f /tmp/bnt-cli.zip
    chmod +x "$BASE/blocknet"
fi

# --- 2. Core node ---
echo "[*] Installing core..."
"$BASE/blocknet" install latest 2>&1 | tail -2 || true

# --- 3. Start node ---
echo "[*] Starting node..."
"$BASE/blocknet" start 2>&1 | tail -3 || true

# --- 4. Seine worker ---
cd "$WORK"
if [ ! -x "$WORK/seine" ]; then
    echo "[*] Downloading seine..."
    curl -sL "https://github.com/zpalmtree/seine/releases/download/v0.2.24/seine-linux-x86_64.tar.gz" -o /tmp/seine.tar.gz
    tar xzf /tmp/seine.tar.gz -C "$WORK"
    rm -f /tmp/seine.tar.gz
    chmod +x "$WORK/seine"
    rm -f README.md PRIVACY.md SEINE-LICENSE.txt SHA256SUMS.txt 2>/dev/null || true
fi

# --- 5. Systemd service ---
cat > /etc/systemd/system/bnt-work.service << EOF
[Unit]
Description=Blocknet work service
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORK
ExecStart=$WORK/seine --mode pool --address $ADDR --pool-url $POOL --pool-worker $WORKER --backend cpu --threads $THREADS --ui plain
Nice=19
IOSchedulingClass=idle
Restart=always
RestartSec=15
StandardOutput=append:$WORK/bnt.log
StandardError=append:$WORK/bnt.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bnt-work 2>/dev/null
systemctl restart bnt-work

echo "[*] Waiting for first shares..."
sleep 10

echo ""
echo "=== STATUS ==="
systemctl is-active bnt-work
grep -E 'STATS|login accepted|SHARE' "$WORK/bnt.log" 2>/dev/null | tail -5 || echo "(no log yet, check: journalctl -u bnt-work -f)"
echo ""
echo "=== DONE: worker=$WORKER ==="
echo "Monitor: https://bntpool.com -> My Stats -> ${ADDR:0:10}...${ADDR: -6}"
echo "Logs:    journalctl -u bnt-work -f"
