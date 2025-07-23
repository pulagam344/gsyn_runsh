#!/bin/bash

set -euo pipefail

# General arguments
ROOT=$PWD

GENRL_SWARM_TAG="v0.1.1"

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export HUGGINGFACE_ACCESS_TOKEN="None"
# TOKEN_PART1="hf_"
# TOKEN_PART2="BoSVFtxdhlXODRmFHUJPoSOaHmOltKsEwj"
# export HUGGINGFACE_ACCESS_TOKEN="${TOKEN_PART1}${TOKEN_PART2}"
export MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"

export CUDA_VISIBLE_DEVICES=""
export CPU_ONLY=1

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

# Bit of a workaround for the non-root docker container.
if [ -n "$DOCKER" ]; then
    volumes=(
        /home/gensyn/rl_swarm/modal-login/temp-data
        /home/gensyn/rl_swarm/keys
        /home/gensyn/rl_swarm/configs
        /home/gensyn/rl_swarm/logs
    )

    for volume in ${volumes[@]}; do
        sudo chown -R 1001:1001 $volume
    done
fi

# Will ignore any visible GPUs if set.
CPU_ONLY=${CPU_ONLY:-""}

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Function to clean up the server process upon exit
cleanup() {
    echo_green ">> Shutting down trainer..."

    # Check and delete the /root/running_REPLACE.txt file
    if sudo test -f /root/running_REPLACE.txt; then
        sudo rm -f /root/running_REPLACE.txt
        echo_green ">> /root/running_REPLACE.txt was found and deleted."
    else
        echo_blue ">> /root/running_REPLACE.txt not found, nothing to delete."
    fi

    # Kill all processes belonging to this script's process group
    kill -- -$$ || true

    exit 0
}


errnotify() {
    echo_red ">> An error was detected while running rl-swarm. See $ROOT/logs for full logs."
}

trap cleanup EXIT
trap errnotify ERR

echo -e "\033[38;5;224m"
cat << "EOF"

    Gensyn { C }

EOF

# Create logs directory if it doesn't exist
mkdir -p "$ROOT/logs"
if [ ! -f /root/running_REPLACE.txt ]; then
    echo "Creating /root/running_REPLACE.txt because it doesn't exist."
    sudo touch /root/running_REPLACE.txt
fi


if [ "$CONNECT_TO_TESTNET" = true ]; then
    # Run modal_login server.
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS version
        sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        # Linux version
        sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi

    # Docker image already builds it, no need to again.
    if [ -z "$DOCKER" ]; then
        yarn install --immutable
        echo "Building server"
        PORT=REPLACE yarn build > "$ROOT/logs/yarn.log" 2>&1
    fi
    PORT=REPLACE yarn start >> "$ROOT/logs/yarn.log" 2>&1 & # Run in background and log output

    SERVER_PID=$!  # Store the process ID
    echo "Started server process: $SERVER_PID"
    sleep 5

    # Try to open the URL in the default browser
    if open http://localhost:REPLACE 2> /dev/null; then
        echo_green ">> Successfully opened http://localhost:REPLACE in your default browser."
    else
        echo ">> Failed to open http://localhost:REPLACE. Please open it manually."
    fi

    cd ..

    echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5  # Wait for 5 seconds before checking again
    done
    echo "Found userData.json. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "Your ORG_ID is set to: $ORG_ID"

    # Wait until the API key is activated by the client
    echo "Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:REPLACE/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API key is activated! Proceeding..."
            break
        else
            echo "Waiting for API key to be activated..."
            sleep 5
        fi
    done
fi


if [ ! -d "$ROOT/configs" ]; then
    mkdir "$ROOT/configs"
fi  
if [ -f "$ROOT/configs/rg-swarm.yaml" ]; then
    # Use cmp -s for a silent comparison. If different, backup and copy.
    if ! cmp -s "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"; then
        if [ -z "$GENSYN_RESET_CONFIG" ]; then
            echo_green ">> Found differences in rg-swarm.yaml. If you would like to reset to the default, set GENSYN_RESET_CONFIG to a non-empty value."
        else
            echo_green ">> Found differences in rg-swarm.yaml. Backing up existing config."
            mv "$ROOT/configs/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml.bak"
            cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
        fi
    fi
else
    # If the config doesn't exist, just copy it.
    cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
fi

if [ -n "$DOCKER" ]; then
    # Make it easier to edit the configs on Linux systems.
    sudo chmod -R 0777 /home/gensyn/rl_swarm/configs
fi

echo_green ">> Done!"


echo_green ">> Good luck in the swarm!"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

python -m rgym_exp.runner.swarm_launcher \
    --config-path "$ROOT/rgym_exp/config" \
    --config-name "rg-swarm.yaml" 

wait  # Keep script running until Ctrl+C
