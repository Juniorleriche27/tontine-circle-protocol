#!/usr/bin/env bash
# ==============================================================================
# Tontine Circle Protocol — Controlled Jetton Deployment Launcher (Bash)
# ==============================================================================
# IMPORTANT: RESERVED FOR FUTURE CONTROLLED TESTNET BROADCAST.
# DO NOT EXECUTE DURING THE READINESS PHASE.
# ==============================================================================

set -euo pipefail

REQUIRED_AUTH="I_UNDERSTAND_THIS_IS_A_REAL_TESTNET_BROADCAST"

echo "============================================================"
echo "TONTINE CIRCLE PROTOCOL — TEST JETTON DEPLOY LAUNCHER (Bash)"
echo "============================================================"

if [ "${TONTINE_ALLOW_TESTNET_BROADCAST:-}" != "$REQUIRED_AUTH" ]; then
    echo "ERROR: Broadcast acknowledgement missing or invalid."
    echo "You must explicitly export:"
    echo "  export TONTINE_ALLOW_TESTNET_BROADCAST=\"$REQUIRED_AUTH\""
    echo "Deployment aborted."
    exit 1
fi

ALLOWED_EXPLORERS=("actonscan" "tonscan" "toncx" "dton" "tonviewer")
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        *--net*|*--fork-net*)
            echo "ERROR: Network flags cannot be passed to this launcher ($1)."
            echo "This launcher strictly enforces '--net testnet'."
            exit 1
            ;;
        --tonconnect)
            FORWARD_ARGS+=("--tonconnect")
            shift
            ;;
        --explorer)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --explorer requires an explorer name argument."
                exit 1
            fi
            EXP_VAL="$2"
            VALID_EXP=false
            for exp in "${ALLOWED_EXPLORERS[@]}"; do
                if [[ "$exp" == "$EXP_VAL" ]]; then
                    VALID_EXP=true
                    break
                fi
            done
            if [[ "$VALID_EXP" != "true" ]]; then
                echo "ERROR: Invalid explorer '$EXP_VAL'. Allowed: ${ALLOWED_EXPLORERS[*]}."
                exit 1
            fi
            FORWARD_ARGS+=("--explorer" "$EXP_VAL")
            shift 2
            ;;
        *)
            echo "ERROR: Unsupported argument '$1'."
            echo "Allowed options are: --tonconnect, --explorer <name>"
            exit 1
            ;;
    esac
done

echo "Network: TESTNET (hardcoded)"
echo "Executing deployTestJetton script with --net testnet..."
echo "============================================================"

acton script contracts/scripts/deployTestJetton.tolk --net testnet "${FORWARD_ARGS[@]}"
