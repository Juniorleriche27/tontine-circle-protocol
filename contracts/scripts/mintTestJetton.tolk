import "@acton/io"
import "@acton/env"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"

import "@wrappers/JettonMinter.gen"
import "deployGuards"

fun main() {
    println("============================================================");
    println("Tontine Protocol — Mint Testnet USDTT Jettons");
    println("Display Convention: 6 Decimals (1 USDTT = 1,000,000 integer units)");
    println("============================================================");

    // 1. Parser l'adresse du Jetton Minter
    var masterAddress = env<address>("TONTINE_USDT_MASTER");
    if (masterAddress == null) {
        masterAddress = promptAddress("Enter Testnet USDT Master address:");
    }

    // 2. Parser le destinataire
    var recipient = env<address>("TONTINE_MINT_RECIPIENT");
    if (recipient == null) {
        recipient = promptAddress("Enter recipient address:");
    }

    // 3. Vérifier les workchains
    val masterWc = masterAddress!.getWorkchain();
    if (!validateWorkchain(masterWc)) {
        println("ERROR: Invalid workchain for USDT Master address.");
        throw 601;
    }
    val recipientWc = recipient!.getWorkchain();
    if (!validateWorkchain(recipientWc)) {
        println("ERROR: Invalid workchain for recipient address.");
        throw 602;
    }

    val minter = JettonMinter.fromAddress(masterAddress!);

    // 4. Parser amount comme int
    var amountInt = env<int>("TONTINE_MINT_AMOUNT");
    if (amountInt == null) {
        amountInt = promptInt("Enter amount in integer units (e.g. 100000000 = 100 USDTT):", "100000000");
    }

    // 5. Vérifier amount > 0 et 6. amount <= MAX_COINS (sans cast préalable)
    if (!validateMintAmount(amountInt!)) {
        println("ERROR: Mint amount ({}) is invalid. Must be > 0 and <= MAX_COINS (2^120 - 1).", amountInt!);
        throw 603;
    }

    // 7. Vérifier que le master est déployé AVANT toute transaction
    if (!scripts.isContractDeployed(minter.address)) {
        println("CRITICAL ERROR: Jetton Master is NOT deployed at {}. Minting aborted.", minter.address);
        throw 604;
    }

    // 8. Obtenir les données on-chain du Minter
    val jettonData = minter.getJettonData();

    // 9. Charger le wallet admin et vérifier que l'admin correspond
    var walletName = env<string>("TONTINE_DEPLOYER_WALLET");
    if (walletName == null) {
        walletName = net.isBroadcasting() ? promptWallet("Select Jetton admin wallet:") : "deployer";
    }
    val admin = scripts.wallet(walletName!);

    if (!isMinterAdminMatching(jettonData.adminAddress, admin.address)) {
        println("CRITICAL ERROR: Signer ({}) does not match registered minter admin ({}). Minting aborted.", admin.address, jettonData.adminAddress);
        throw 605;
    }

    // 10. Lire initialSupply et 11. vérifier initialSupply <= MAX_COINS
    val initialSupply = jettonData.totalSupply;
    if (initialSupply < 0 || initialSupply > MAX_COINS) {
        println("CRITICAL ERROR: On-chain initial supply ({}) exceeds MAX_COINS bound.", initialSupply);
        throw 608;
    }

    // 12. Vérifier que initialSupply <= MAX_COINS - amount (canMintWithoutSupplyOverflow)
    if (!canMintWithoutSupplyOverflow(initialSupply, amountInt!)) {
        println("CRITICAL ERROR: Cumulative supply overflow! initialSupply ({}) + amount ({}) exceeds MAX_COINS.", initialSupply, amountInt!);
        throw 609;
    }

    // 13. Afficher le résumé
    println("Minter Address:        {}", masterAddress!);
    println("Admin Wallet:          {}", admin.address);
    println("Recipient:             {}", recipient!);
    println("Amount (integer units): {}", amountInt!);
    println("Current Total Supply:  {}", initialSupply);
    println("Projected Total Supply: {}", initialSupply + amountInt!);
    if (net.isBroadcasting()) {
        println("Expected network:      TESTNET (Network identity not introspectable from Tolk)");
    } else {
        println("Network mode:          LOCAL EMULATION");
    }

    // 14. Si broadcast : opt-in acknowledgement
    if (net.isBroadcasting()) {
        val authValue = env<string>("TONTINE_ALLOW_TESTNET_BROADCAST");
        if (!isBroadcastOptInAcknowledged(authValue)) {
            println("MINTING ABORTED: Missing or invalid broadcast acknowledgement.");
            println("Set TONTINE_ALLOW_TESTNET_BROADCAST=\"{}\"", BROADCAST_OPT_IN_ACK_VALUE);
            return;
        }

        println("************************************************************");
        println("PRE-BROADCAST CONFIRMATION: MINT TEST JETTONS");
        println("************************************************************");
        println("REAL BROADCAST:         YES");
        println("EXPECTED NETWORK:       TESTNET");
        println("Recipient:              {}", recipient!);
        println("Amount (integer units): {}", amountInt!);
        println("Forward Gas:            0.5 TON");
        println("************************************************************");

        // 15. Confirmation interactive avec défaut false
        val userConfirmed = confirm(
            "CONFIRM BROADCAST: Send mint transaction to TESTNET?",
            false,
            "Default is NO (false)."
        );
        if (!userConfirmed) {
            println("MINTING ABORTED: Confirmation rejected.");
            return;
        }
    }

    // 16. Seulement maintenant, cast sécurisé vers coins et construction du message
    val amountCoins = amountInt! as coins;

    val internalMsg = beginCell()
        .storeUint(0x178d4519, 32) // internal_transfer opcode
        .storeUint(1, 64)          // queryId
        .storeCoins(amountCoins)
        .storeAddress(admin.address)
        .storeAddress(admin.address)
        .storeCoins(0)
        .storeUint(0, 1)           // empty forward payload
        .endCell();

    val mintMsg = beginCell()
        .storeUint(0x642b7d07, 32) // mint opcode
        .storeUint(1, 64)          // queryId
        .storeAddress(recipient!)
        .storeCoins(grams("0.2"))  // forward ton for wallet deployment/fees
        .storeRef(internalMsg)
        .endCell();

    println("Sending mint transaction (0.5 TON)...");
    val sendRes = minter.sendAny(admin.address, mintMsg, { value: grams("0.5") });

    // Attente de la trace complète (transaction racine et transactions descendantes)
    val trace = sendRes.waitForTrace();
    if (trace == null) {
        println("MINT NOT VERIFIED / FAILURE: No settled transaction trace observed.");
        throw 606;
    }

    // Vérification objective post-mint avec sondage borné (bounded polling, 5 tentatives)
    val expectedSupply = initialSupply + amountCoins;
    var verified = false;
    var postSupply: coins = 0;
    var attempt = 0;
    while (!verified && attempt < 5) {
        attempt += 1;
        val postData = minter.getJettonData();
        postSupply = postData.totalSupply;
        if (postSupply == expectedSupply) {
            verified = true;
        }
    }

    if (!verified) {
        println("MINT NOT VERIFIED / FAILURE: Expected total supply {}, got {} after {} attempt(s)", expectedSupply, postSupply, attempt);
        throw 607;
    }

    val recipientWallet = minter.getWalletAddress(recipient!);
    println("\n============================================================");
    println("MINT VERIFIED SUCCESSFULLY");
    println("============================================================");
    println("Total Supply before:   {}", initialSupply);
    println("Total Supply after:    {}", postSupply);
    println("Recipient Jetton Wallet: {}", recipientWallet);
    println("============================================================");
}
