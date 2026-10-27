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

# --- detect init system ---
HAS_SYSTEMD=0
if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
    HAS_SYSTEMD=1
    echo "[*] Init: systemd"
else
    echo "[*] Init: none (container/sandbox mode)"
fi

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

# --- 3. Start node (background, don't block) ---
echo "[*] Starting node..."
nohup "$BASE/blocknet" start > "$WORK/node-start.log" 2>&1 &
echo "[*] Node starting in background, PID $!"

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

# --- 5. Start worker ---
if [ "$HAS_SYSTEMD" = "1" ]; then
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
    echo "[*] Service: bnt-work (systemd)"
else
    # Container mode: nohup + pidfile
    if [ -f "$WORK/bnt.pid" ]; then
        kill "$(cat $WORK/bnt.pid)" 2>/dev/null || true
        rm -f "$WORK/bnt.pid"
    fi
    nohup "$WORK/seine" --mode pool --address "$ADDR" --pool-url "$POOL" \
        --pool-worker "$WORKER" --backend cpu --threads "$THREADS" --ui plain \
        >> "$WORK/bnt.log" 2>&1 &
    echo $! > "$WORK/bnt.pid"
    echo "[*] Worker started (nohup, PID $(cat $WORK/bnt.pid))"
fi

echo "[*] Waiting for first shares..."
sleep 10

echo ""
echo "=== STATUS ==="
if [ "$HAS_SYSTEMD" = "1" ]; then
    systemctl is-active bnt-work
    echo "Logs: journalctl -u bnt-work -f"
else
    if [ -f "$WORK/bnt.pid" ] && kill -0 "$(cat $WORK/bnt.pid)" 2>/dev/null; then
        echo "Worker: RUNNING (PID $(cat $WORK/bnt.pid))"
    else
        echo "Worker: NOT RUNNING"
    fi
    echo "Logs: tail -f $WORK/bnt.log"
fi
grep -E 'STATS|login accepted|SHARE' "$WORK/bnt.log" 2>/dev/null | tail -5 || echo "(no shares yet)"
echo ""
echo "=== DONE: worker=$WORKER ==="
echo "Monitor: https://bntpool.com -> My Stats -> ${ADDR:0:10}...${ADDR: -6}"
