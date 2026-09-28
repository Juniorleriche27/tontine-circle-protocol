# ==============================================================================
# Tontine Circle Protocol — Controlled Jetton Deployment Launcher (PowerShell)
# ==============================================================================
# IMPORTANT: RESERVED FOR FUTURE CONTROLLED TESTNET BROADCAST.
# DO NOT EXECUTE DURING THE READINESS PHASE.
# ==============================================================================

$ErrorActionPreference = "Stop"

$RequiredAuth = "I_UNDERSTAND_THIS_IS_A_REAL_TESTNET_BROADCAST"

Write-Host "============================================================"
Write-Host "TONTINE CIRCLE PROTOCOL - TEST JETTON DEPLOY LAUNCHER (PowerShell)"
Write-Host "============================================================"

# 1. Verifier l'opt-in de broadcast (non-secret acknowledgement)
if ($env:TONTINE_ALLOW_TESTNET_BROADCAST -ne $RequiredAuth) {
    Write-Host "ERROR: Broadcast acknowledgement missing or invalid." -ForegroundColor Red
    Write-Host "You must explicitly set:"
    Write-Host '  $env:TONTINE_ALLOW_TESTNET_BROADCAST = "I_UNDERSTAND_THIS_IS_A_REAL_TESTNET_BROADCAST"'
    Write-Host "Deployment aborted."
    exit 1
}

# 2. Strict allow-list parsing
$AllowedExplorers = @("actonscan", "tonscan", "toncx", "dton", "tonviewer")
$ForwardArgs = @()

$i = 0
while ($i -lt $args.Count) {
    $arg = $args[$i]

    if ($arg -like "*--net*" -or $arg -like "*--fork-net*") {
        Write-Host "ERROR: Network flags cannot be passed to this launcher ($arg)." -ForegroundColor Red
        Write-Host "This launcher strictly enforces '--net testnet'."
        exit 1
    }

    if ($arg -eq "--tonconnect") {
        $ForwardArgs += "--tonconnect"
        $i++
    }
    elseif ($arg -eq "--explorer") {
        if ($i + 1 -ge $args.Count) {
            Write-Host "ERROR: --explorer requires an explorer name argument." -ForegroundColor Red
            exit 1
        }
        $expVal = $args[$i + 1]
        if ($AllowedExplorers -notcontains $expVal) {
            Write-Host "ERROR: Invalid explorer '$expVal'. Allowed values: $($AllowedExplorers -join ', ')." -ForegroundColor Red
            exit 1
        }
        $ForwardArgs += "--explorer"
        $ForwardArgs += $expVal
        $i += 2
    }
    else {
        Write-Host "ERROR: Unsupported argument '$arg'." -ForegroundColor Red
        Write-Host "Allowed options are: --tonconnect, --explorer <name>" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Network: TESTNET (hardcoded)"
Write-Host "Executing deployTestJetton script with --net testnet..."
Write-Host "============================================================"

& acton script contracts/scripts/deployTestJetton.tolk --net testnet @ForwardArgs
