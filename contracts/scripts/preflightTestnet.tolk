import "@acton/io"
import "@acton/env"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/ffi"

import "@wrappers/TontineCircle.gen"
import "@wrappers/JettonMinter.gen"
import "../tontineStorage"
import "../tontineTypes"
import "deployGuards"

fun main() {
    println("============================================================");
    println("TON Tontine Protocol — Read-Only Testnet Preflight");
    println("Mode: READ-ONLY / FORK-NET (No broadcast, no funds spent)");
    println("============================================================");

    var criticalFailuresCount: int = 0;
    var warningsCount: int = 0;

    // 1. Obtenir et valider l'adresse réelle prévue pour le controller
    var controller = env<address>("TONTINE_CONTROLLER_ADDRESS");
    if (controller == null) {
        controller = promptAddress("Enter intended Testnet Controller address:");
    }
    val controllerWc = controller!.getWorkchain();
    if (!validateWorkchain(controllerWc)) {
        println("[CRITICAL FAIL] Invalid workchain ({}) for Controller address.", controllerWc);
        println("PRE-FLIGHT RESULT: NO-GO (Structural input parameter failure)");
        println("============================================================");
        throw 301;
    }
    println("[CRITICAL PASS] Controller address syntax and workchain valid ({})", controllerWc);

    // 2. Obtenir et valider circleId (uint64) AVANT tout cast ou calcul
    var circleIdInt = env<int>("TONTINE_CIRCLE_ID");
    if (circleIdInt == null) {
        circleIdInt = promptInt("Enter Circle ID (uint64):", "1");
    }
    if (!validateCircleId(circleIdInt!)) {
        println("[CRITICAL FAIL] Circle ID ({}) is outside valid uint64 range [0, 2^64-1].", circleIdInt!);
        println("PRE-FLIGHT RESULT: NO-GO (Structural input parameter failure)");
        println("============================================================");
        throw 301;
    }
    println("[CRITICAL PASS] Circle ID ({}) within uint64 range.", circleIdInt!);
    val circleId = circleIdInt! as uint64;

    // 3. Obtenir et valider l'adresse USDT Master (Minter TEP-74)
    var usdtMaster = env<address>("TONTINE_USDT_MASTER");
    if (usdtMaster == null) {
        usdtMaster = promptAddress("Enter Testnet USDT Master address:");
    }
    val masterWc = usdtMaster!.getWorkchain();
    if (!validateWorkchain(masterWc)) {
        println("[CRITICAL FAIL] Invalid workchain ({}) for USDT Master address.", masterWc);
        println("PRE-FLIGHT RESULT: NO-GO (Structural input parameter failure)");
        println("============================================================");
        throw 301;
    }
    println("[CRITICAL PASS] USDT Master address syntax and workchain valid ({})", masterWc);

    // 4. Obtenir et valider l'adresse Protocol Treasury
    var protocolTreasury = env<address>("TONTINE_PROTOCOL_TREASURY");
    if (protocolTreasury == null) {
        protocolTreasury = promptAddress("Enter Testnet Protocol Treasury address:");
    }
    val treasuryWc = protocolTreasury!.getWorkchain();
    if (!validateWorkchain(treasuryWc)) {
        println("[CRITICAL FAIL] Invalid workchain ({}) for Protocol Treasury address.", treasuryWc);
        println("PRE-FLIGHT RESULT: NO-GO (Structural input parameter failure)");
        println("============================================================");
        throw 301;
    }
    println("[CRITICAL PASS] Protocol Treasury address syntax and workchain valid ({})", treasuryWc);

    // 5. Construire le storage canonique avec le vrai controller prévu
    val initialStorage = buildInitialTontineStorage(
        circleId,
        controller!,
        usdtMaster!,
        protocolTreasury!,
    );

    // 6. Calculer StateInit et adresse TontineCircle de façon strictement déterministe
    val contract = TontineCircle.fromStorage(initialStorage);

    println("\n--- Planned Deployment Parameters ---");
    println("Controller (Intended):  {}", controller!);
    println("Circle ID:              {}", circleId);
    println("USDT Master:            {}", usdtMaster!);
    println("Protocol Treasury:      {}", protocolTreasury!);
    println("Calculated Contract:    {}", contract.address);

    println("\n--- Automated Preflight Checks ---");

    // CRITICAL CHECK: Absence de contrat déjà déployé à cette adresse
    val targetDeployed = scripts.isContractDeployed(contract.address);
    if (targetDeployed) {
        println("[CRITICAL FAIL] Target contract address collision: already deployed at {}", contract.address);
        criticalFailuresCount += 1;
    } else {
        println("[CRITICAL PASS] Target address is clean (no contract currently deployed at {})", contract.address);
    }

    // ACCOUNT STATUS & THRESHOLDS: Controller
    val ctrlDeployed = scripts.isContractDeployed(controller!);
    val ctrlBalance = scripts.fetchAccountBalance(controller!);
    println("[INFO] Controller deployed on-chain: {} | Balance: {:gram}", ctrlDeployed, ctrlBalance);
    if (ctrlBalance < PREFLIGHT_MIN_CONTROLLER_BALANCE) {
        println("[WARN] Controller balance ({:gram}) is below preflight operational threshold ({:gram}).", ctrlBalance, PREFLIGHT_MIN_CONTROLLER_BALANCE);
        println("       Note: threshold is operational and does not guarantee network costs.");
        warningsCount += 1;
    } else {
        println("[INFO] Controller balance passed preflight minimum operational threshold ({:gram})", PREFLIGHT_MIN_CONTROLLER_BALANCE);
    }
    println("[MANUAL CHECK] Verify physical ownership of Controller wallet and equality with future broadcast wallet.");

    // ACCOUNT STATUS: Protocol Treasury
    val treasuryDeployed = scripts.isContractDeployed(protocolTreasury!);
    val treasuryBalance = scripts.fetchAccountBalance(protocolTreasury!);
    println("[INFO] Treasury deployed on-chain: {} | Balance: {:gram}", treasuryDeployed, treasuryBalance);
    println("[MANUAL CHECK] Verify Treasury address belongs to protocol multisig/governance.");

    // CRITICAL CHECKS: Jetton Master (TEP-74 / TEP-89)
    val masterDeployed = scripts.isContractDeployed(usdtMaster!);
    if (!masterDeployed) {
        println("[CRITICAL FAIL] Jetton Master is NOT deployed at {}", usdtMaster!);
        criticalFailuresCount += 1;
    } else {
        println("[CRITICAL PASS] Jetton Master is deployed at {}", usdtMaster!);
        val minter = JettonMinter.fromAddress(usdtMaster!);

        var onChainAdminAddress: address? = null;
        var dataSuccess = false;
        try {
            val jettonData = minter.getJettonData();
            dataSuccess = true;
            onChainAdminAddress = jettonData.adminAddress;
            println("[CRITICAL PASS] Jetton Master get_jetton_data responsive (Observed TotalSupply: {}, Mintable: {})", jettonData.totalSupply, jettonData.mintable);
        } catch (err) {
            println("[CRITICAL FAIL] Jetton Master get_jetton_data failed with code: {}", err);
            criticalFailuresCount += 1;
        }

        // Expected admin check (fail-closed)
        val rawExpectedAdmin = env<string>("TONTINE_EXPECTED_JETTON_ADMIN");
        val [adminConfigured, adminMalformed, parsedExpectedAdmin] = parseExpectedAdminAddress(rawExpectedAdmin);
        val adminCheckStatus = evaluateExpectedAdminCheck(adminConfigured, adminMalformed, parsedExpectedAdmin, onChainAdminAddress);
        if (adminCheckStatus == 1) {
            println("[CRITICAL PASS] Jetton Master admin matches expected admin: {}", parsedExpectedAdmin!);
        } elseif (adminCheckStatus == 2) {
            println("[CRITICAL FAIL] TONTINE_EXPECTED_JETTON_ADMIN is present but malformed: '{}'", rawExpectedAdmin!);
            criticalFailuresCount += 1;
        } elseif (adminCheckStatus == 3) {
            println("[CRITICAL FAIL] Jetton Master admin mismatch! Observed: {}, Expected: {}", onChainAdminAddress, parsedExpectedAdmin);
            criticalFailuresCount += 1;
        } else {
            println("[MANUAL CHECK] Compare Jetton Master admin ({}) against approved team admin.", onChainAdminAddress);
        }

        var walletSuccess = false;
        try {
            val walletAddr = minter.getWalletAddress(controller!);
            walletSuccess = true;
            println("[CRITICAL PASS] Jetton Master get_wallet_address responsive (Controller wallet: {})", walletAddr);
        } catch (err) {
            println("[CRITICAL FAIL] Jetton Master get_wallet_address failed with code: {}", err);
            criticalFailuresCount += 1;
        }

        val masterCode = ffi.getDeployedCode(usdtMaster!.toCell());
        if (masterCode != null) {
            val observedHash = masterCode!.hash();
            println("[INFO] Observed Jetton Master code hash: 0x{:x}", observedHash);

            // Expected code hash check (fail-closed)
            val rawExpectedHash = env<string>("TONTINE_EXPECTED_MASTER_CODE_HASH");
            val [hashConfigured, hashMalformed, parsedExpectedHash] = parseExpectedCodeHash(rawExpectedHash);
            val hashCheckStatus = evaluateExpectedCodeHashCheck(hashConfigured, hashMalformed, parsedExpectedHash, observedHash);
            if (hashCheckStatus == 1) {
                println("[CRITICAL PASS] Jetton Master code hash matches approved fingerprint (0x{:x})", parsedExpectedHash);
            } elseif (hashCheckStatus == 2) {
                println("[CRITICAL FAIL] TONTINE_EXPECTED_MASTER_CODE_HASH is present but malformed: '{}'", rawExpectedHash!);
                criticalFailuresCount += 1;
            } elseif (hashCheckStatus == 3) {
                println("[CRITICAL FAIL] Jetton Master code hash mismatch! Observed: 0x{:x}, Expected: 0x{:x}", observedHash, parsedExpectedHash);
                criticalFailuresCount += 1;
            } else {
                println("[MANUAL CHECK] Compare observed code hash 0x{:x} against approved JettonMinter fingerprint.", observedHash);
            }
        } else {
            println("[CRITICAL FAIL] Jetton Master deployed code is missing or unreadable.");
            criticalFailuresCount += 1;
        }

        if (dataSuccess && walletSuccess) {
            println("[INFO] Master interface checks passed; identity still requires approved fingerprint comparison.");
        }
    }

    println("\n============================================================");
    println("GO / NO-GO PREFLIGHT VERIFICATION MATRIX");
    println("============================================================");
    println("1. Parameters Parsing & Workchain:   [PASS]");
    println("2. Target Address Free:              [{}]", targetDeployed ? "FAIL" : "PASS");
    println("3. Master Contract Deployed:         [{}]", masterDeployed ? "PASS" : "FAIL");
    println("4. Preflight Threshold Warnings:     {}", warningsCount);
    println("5. Critical Failures Count:          {}", criticalFailuresCount);
    println("============================================================");

    val reviewStatus = evaluatePreflightReviewStatus(criticalFailuresCount, warningsCount);
    if (criticalFailuresCount > 0) {
        println("PRE-FLIGHT RESULT: NO-GO ({} critical check(s) failed)", criticalFailuresCount);
        println("Deployment cannot proceed. Rectify all critical failures before retrying.");
        println("============================================================");
        throw 301;
    }

    println("PRE-FLIGHT RESULT: GO FOR MANUAL REVIEW");
    println("All automated critical checks passed.");
    println("Operator MUST perform manual checks before any broadcast:");
    println("  - Confirm controller physical possession and equality with broadcast wallet");
    println("  - Confirm Treasury address governance and multisig configuration");
    println("  - Confirm Jetton Master code hash matches approved USDTT fingerprint");
    println("  - Confirm active connection is on TON Testnet");
    println("============================================================");
}
