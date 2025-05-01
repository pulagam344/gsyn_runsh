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

    # Wait for user to log in
    echo "👉 Please open the ngrok URL to log in"
    
    # Start ngrok
    if ! command -v ngrok > /dev/null; then
        echo "Downloading and installing ngrok..."
        ARCH=$(uname -m)
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')

        if [ "$ARCH" = "x86_64" ]; then
            NGROK_ARCH="amd64"
        elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
            NGROK_ARCH="arm64"
        else
            echo "❌ Unsupported architecture: $ARCH"
            exit 1
        fi

        wget -q "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"
        tar -xzf "ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"
        sudo mv ngrok /usr/local/bin/
        rm "ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"
    fi

    NGROK_TOKEN="2vIktq0KK4TBzkfFdk9zBMLtvVR_47EmaHeJJuUcwsmhEvRmF"
    ngrok authtoken "$NGROK_TOKEN"

    ngrok http 3000 > /dev/null &
    NGROK_PID=$!
    echo "🌀 ngrok started, waiting for tunnel..."

    # Wait for tunnel to become active
    sleep 10
    FORWARDING_URL=""
    for i in {1..5}; do
        FORWARDING_URL=$(curl -s http://127.0.0.1:4040/api/tunnels | grep -o 'https://[^"]*' | head -n 1 || true)
        if [ -n "$FORWARDING_URL" ]; then
            break
        fi
        sleep 5
    done

    if [ -z "$FORWARDING_URL" ]; then
        echo "❌ Failed to retrieve ngrok tunnel URL."
        exit 1
    fi

    echo "✅ Ngrok tunnel available: $FORWARDING_URL"
    echo "👉 Please open the following URL to log in:"
    echo "$FORWARDING_URL"

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
    echo "🧹 Shutting down ngrok and login server..."
    kill $NGROK_PID 2>/dev/null || true
    pkill -f "yarn dev" 2>/dev/null || true
    exit 0
}

trap cleanup INT
wait
