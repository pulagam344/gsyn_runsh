#!/bin/bash

set -euo pipefail

# ========== Configuration ==========

ROOT=$PWD
DEFAULT_PUB_MULTI_ADDRS=""
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

export PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}
export PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}
export HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}
export IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}
export HF_HUB_DOWNLOAD_TIMEOUT=120

# ========== User Inputs ==========

CONNECT_TO_TESTNET=true
USE_BIG_SWARM=true
PARAM_B=0.5
HF_TOKEN="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"

echo "Using defaults:"
echo "✅ Connect to testnet: $CONNECT_TO_TESTNET"
echo "✅ Swarm: Math Hard (Big Swarm)"
echo "✅ Parameter size: ${PARAM_B}B"

# ========== Ethereum Wallet Setup ==========

if [ "$CONNECT_TO_TESTNET" = true ]; then
    echo "🚀 Preparing Ethereum wallet setup..."
    cd modal-login || exit 1

    # Install Node.js and Yarn
    if ! command -v node > /dev/null; then
        echo "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi

    if ! command -v yarn > /dev/null; then
        echo "Installing Yarn..."
        npm install --global yarn
    fi

    yarn install
    nohup yarn dev > ../modal-login.log 2>&1 &
    echo "🌀 Login server started in background (manual access needed)"
    
    cd ..

    # Instruct user to access login page directly (no ngrok)
    echo "👉 Please open the login page on http://localhost:3000 to log in"

    echo "⏳ Waiting for userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5
    done
    echo "✅ Found userData.json. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "✅ ORG_ID set to: $ORG_ID"

    # Wait for API key activation
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "✅ API key activated!"
            break
        else
            echo "⏳ Waiting for API key activation..."
            sleep 5
        fi
    done

    sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$BIG_SWARM_CONTRACT/" "$ROOT/modal-login/.env"
else
    ORG_ID=""
fi

# ========== Install Requirements ==========

echo "📦 Installing Python dependencies..."
pip install --upgrade pip

if [ -n "${CPU_ONLY:-}" ] || ! command -v nvidia-smi > /dev/null; then
    pip install -r "$ROOT/requirements-cpu.txt"
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
else
    pip install -r "$ROOT/requirements-gpu.txt"
    pip install flash-attn --no-build-isolation

    case "$PARAM_B" in
        32 | 72) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
        0.5 | 1.5 | 7) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
        *) echo "❌ Invalid parameter size."; exit 1 ;;
    esac

    GAME=$([ "$USE_BIG_SWARM" = true ] && echo "dapo" || echo "gsm8k")
fi

# ========== Start Training ==========

echo "🚀 Starting training..."

if [ -n "$ORG_ID" ]; then
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HF_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --contract_address "$BIG_SWARM_CONTRACT" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
else
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HF_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
fi

# ========== Cleanup ==========

cleanup() {
    echo "🧹 Shutting down login server..."
    pkill -f "yarn dev" 2>/dev/null || true
    exit 0
}

trap cleanup INT
wait
