import "@acton/io"
import "@acton/env"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"

import "@wrappers/TontineCircle.gen"
import "../tontineStorage"
import "../tontineTypes"
import "deployGuards"

fun main() {
    // 1. Charger le wallet deployer / controller
    var walletName = env<string>("TONTINE_DEPLOYER_WALLET");
    if (walletName == null) {
        walletName = net.isBroadcasting() ? promptWallet("Select deployer wallet:") : "deployer";
    }
    val deployer = scripts.wallet(walletName!);
    val controller = deployer.address;

    // 2. Obtenir et valider circleId (uint64)
    var circleIdInt = env<int>("TONTINE_CIRCLE_ID");
    if (circleIdInt == null) {
        circleIdInt = promptInt("Enter Circle ID (uint64):", "1");
    }
    if (!validateCircleId(circleIdInt!)) {
        println("ERROR: Circle ID is outside the valid uint64 range [0, 2^64-1].");
        return;
    }
    val circleId = circleIdInt! as uint64;

    // 3. Obtenir et valider l'adresse USDT Master (Minter TEP-74)
    var usdtMaster = env<address>("TONTINE_USDT_MASTER");
    if (usdtMaster == null) {
        usdtMaster = promptAddress("Enter USDT Master address:");
    }
    val masterWc = usdtMaster!.getWorkchain();
    if (!validateWorkchain(masterWc)) {
        println("ERROR: Invalid workchain for USDT Master address.");
        return;
    }

    // 4. Obtenir et valider l'adresse Protocol Treasury
    var protocolTreasury = env<address>("TONTINE_PROTOCOL_TREASURY");
    if (protocolTreasury == null) {
        protocolTreasury = promptAddress("Enter Protocol Treasury address:");
    }
    val treasuryWc = protocolTreasury!.getWorkchain();
    if (!validateWorkchain(treasuryWc)) {
        println("ERROR: Invalid workchain for Protocol Treasury address.");
        return;
    }

    // 5. Construire le storage canonique via le builder officiel
    val initialStorage = buildInitialTontineStorage(
        circleId,
        controller,
        usdtMaster!,
        protocolTreasury!,
    );

    // 6. Calculer et créer l'instance du contrat TontineCircle
    val contract = TontineCircle.fromStorage(initialStorage);

    // 7. Afficher l'adresse prévue et les paramètres AVANT envoi
    println("============================================================");
    println("Tontine Circle Protocol — Canonical Deployment");
    println("============================================================");
    println("Circle ID:             {}", circleId);
    println("Controller (Deployer): {}", controller);
    println("USDT Master:           {}", usdtMaster!);
    println("Protocol Treasury:     {}", protocolTreasury!);
    println("Calculated Address:    {}", contract.address);
    println("Broadcasting Mode:     {}", net.isBroadcasting());
    println("============================================================");

    // 8. Barrières de sécurité strictes en cas de broadcast réel
    if (net.isBroadcasting()) {
        // Barrière A: Variable d'acquittement explicite obligatoire (opt-in phrase)
        val authValue = env<string>("TONTINE_ALLOW_TESTNET_BROADCAST");
        if (!isBroadcastOptInAcknowledged(authValue)) {
            println("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            println("DEPLOYMENT ABORTED: Missing or invalid broadcast acknowledgement.");
            println("To broadcast on Testnet, you must explicitly set:");
            println("TONTINE_ALLOW_TESTNET_BROADCAST=\"{}\"", BROADCAST_OPT_IN_ACK_VALUE);
            println("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            return;
        }

        // Barrière B: Récapitulatif solennel avant émission
        println("************************************************************");
        println("PRE-BROADCAST SAFETY BARRIER");
        println("************************************************************");
        println("REAL BROADCAST:         YES");
        println("EXPECTED NETWORK:       TESTNET");
        println("Controller:             {}", controller);
        println("Circle ID:              {}", circleId);
        println("Jetton Master:          {}", usdtMaster!);
        println("Protocol Treasury:      {}", protocolTreasury!);
        println("Calculated Address:     {}", contract.address);
        println("Value Sent:             0.1 TON");
        println("REMINDER: Verify all parameters off-chain before confirming.");
        println("************************************************************");

        // Barrière C: Confirmation interactive obligatoire avec défaut false
        val userConfirmed = confirm(
            "CONFIRM BROADCAST: Send real transaction to TESTNET?",
            false,
            "This will broadcast a real transaction to the network. Default is NO (false)."
        );
        if (!userConfirmed) {
            println("DEPLOYMENT ABORTED: Confirmation rejected or non-interactive default.");
            return;
        }
    }

    // 9. Déployer
    println("Deploying TontineCircle with 0.1 TON initial balance...");
    val deployResult = contract.deploy(deployer.address, { value: grams("0.1") });

    // 10. Attendre la première transaction
    val tx = deployResult.waitForFirstTransaction();
    if (tx == null) {
        println("Deployment aborted: no transaction observed.");
        return;
    }

    // 11. Afficher le résultat et vérifier les getters post-déploiement
    println("Contract successfully deployed at {}", contract.address);
    println("--- Verifying Initial Canonical State via Getters ---");

    val qId = contract.lastOperationQueryId();
    val resolved = contract.circleJettonWalletResolved();
    val lookupPending = contract.circleJettonWalletLookupPending();
    val st = contract.state();
    val curRound = contract.currentRound();
    val mCount = contract.memberCount();
    val regCount = contract.registeredCount();
    val bCount = contract.fundedBondCount();
    val coll = contract.roundCollected();
    val feeAccrued = contract.protocolFeesAccrued();

    println("1. lastOperationQueryId:           {} (expected 0)", qId);
    println("2. circleJettonWalletResolved:      {} (expected false)", resolved);
    println("3. circleJettonWalletLookupPending: {} (expected false)", lookupPending);
    println("4. state:                          {} (expected 1 / OPEN)", st);
    println("5. currentRound:                   {} (expected 0)", curRound);
    println("6. memberCount:                    {} (expected 10)", mCount);
    println("7. registeredCount:                {} (expected 0)", regCount);
    println("8. fundedBondCount:                {} (expected 0)", bCount);
    println("9. roundCollected:                 {} (expected 0)", coll);
    println("10. protocolFeesAccrued:           {} (expected 0)", feeAccrued);

    assert (qId == 0) throw 201;
    assert (!resolved) throw 202;
    assert (!lookupPending) throw 203;
    assert (st == 1) throw 204;
    assert (curRound == 0) throw 205;
    assert (mCount == 10) throw 206;
    assert (regCount == 0) throw 207;
    assert (bCount == 0) throw 208;
    assert (coll == 0) throw 209;
    assert (feeAccrued == 0) throw 210;

    println("============================================================");
    println("Canonical deployment and state verification SUCCESSFUL!");
    println("Next step: Call BeginCircleJettonWalletResolution (0x52434A57)");
    println("from controller to resolve circle's canonical USDT Jetton wallet.");
    println("============================================================");
}
