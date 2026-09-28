import "@stdlib/strings"
import "@acton/io"
import "@acton/env"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/ffi"

import "@wrappers/JettonMinter.gen"
import "../jetton/storage"
import "deployGuards"

fun buildTestJettonMetadata(
    name: string,
    symbol: string,
    decimals: string,
    uri: string,
): cell {
    var metadata: OnchainMetadataReply = { contentDict: [] };
    metadata.contentDict.set("name".sha256(), name.prefixWith00());
    metadata.contentDict.set("symbol".sha256(), symbol.prefixWith00());
    metadata.contentDict.set("decimals".sha256(), decimals.prefixWith00());
    metadata.contentDict.set("uri".sha256(), uri.prefixWith00());
    return metadata.toCell();
}

fun main() {
    println("============================================================");
    println("Tontine Protocol — Deploy Testnet Jetton Minter (USDTT)");
    println("Display Convention: 6 Decimals (1 USDTT = 1,000,000 integer units)");
    println("============================================================");

    // 1. Charger le portefeuille admin
    var walletName = env<string>("TONTINE_DEPLOYER_WALLET");
    if (walletName == null) {
        walletName = net.isBroadcasting() ? promptWallet("Select Jetton admin wallet:") : "deployer";
    }
    val admin = scripts.wallet(walletName!);

    // 2. Construire les métadonnées officielles du Jetton de test (convention 6 décimales)
    val metadata = buildTestJettonMetadata(
        "Tontine Test Jetton",
        "USDTT",
        "6",
        "https://tontine.finance/usdtt.json"
    );

    // 3. Initialiser le JettonMinter canonique
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: admin.address,
        metadata,
        nextAdminAddress: null,
    });

    println("Jetton Admin:          {}", admin.address);
    println("Decimals Convention:  6 (Metadata/display only, contract units are integers)");
    println("Symbol:                USDTT");
    println("Calculated Minter:     {}", minter.address);
    if (net.isBroadcasting()) {
        println("Expected network:      TESTNET (Network identity not introspectable from Tolk)");
    } else {
        println("Network mode:          LOCAL EMULATION");
    }

    // 4. Barrières de sécurité si broadcast réel
    if (net.isBroadcasting()) {
        val authValue = env<string>("TONTINE_ALLOW_TESTNET_BROADCAST");
        if (!isBroadcastOptInAcknowledged(authValue)) {
            println("DEPLOYMENT ABORTED: Missing or invalid broadcast acknowledgement.");
            println("Set TONTINE_ALLOW_TESTNET_BROADCAST=\"{}\"", BROADCAST_OPT_IN_ACK_VALUE);
            return;
        }

        println("************************************************************");
        println("PRE-BROADCAST CONFIRMATION: TEST JETTON MINTER");
        println("************************************************************");
        println("REAL BROADCAST:         YES");
        println("EXPECTED NETWORK:       TESTNET");
        println("Target Address:         {}", minter.address);
        println("Deposit:                1.0 TON");
        println("************************************************************");

        val userConfirmed = confirm(
            "CONFIRM BROADCAST: Deploy test Jetton Minter to TESTNET?",
            false,
            "Default is NO (false)."
        );
        if (!userConfirmed) {
            println("DEPLOYMENT ABORTED: Confirmation rejected.");
            return;
        }
    }

    println("Deploying JettonMinter with 1.0 TON...");
    val deployRes = minter.deploy(admin.address, { value: grams("1") });
    val tx = deployRes.waitForFirstTransaction();
    if (tx == null) {
        println("Deployment aborted: no transaction observed.");
        return;
    }

    println("Minter successfully deployed at {}", minter.address);

    // 5. Post-deployment verification of responsive getters
    val data = minter.getJettonData();
    assert (data.totalSupply == 0) throw 501;
    assert (data.mintable) throw 502;
    assert (data.adminAddress != null && data.adminAddress! == admin.address) throw 503;
    assert (data.jettonWalletCode != null) throw 504;

    val adminWallet = minter.getWalletAddress(admin.address);
    println("Verified: totalSupply = 0, mintable = true, admin = {}", data.adminAddress);
    println("Derived admin wallet address: {}", adminWallet);

    val code = ffi.getDeployedCode(minter.address.toCell());
    if (code != null) {
        println("Minter Code Hash: 0x{:x}", code!.hash());
    }

    println("\n============================================================");
    println("JETTON MASTER IDENTITY SHEET — SAVE TO ARCHIVES");
    println("============================================================");
    println("Address:               {}", minter.address);
    if (net.isBroadcasting()) {
        println("Network:               testnet (expected)");
    } else {
        println("Network:               local emulation");
    }
    println("Admin:                 {}", admin.address);
    println("Decimals Convention:  6 (display convention, integer accounting)");
    println("Symbol:                USDTT");
    println("Metadata URI:          https://tontine.finance/testnet-usdt.json");
    if (code != null) {
        println("Code Hash:             0x{:x}", code!.hash());
    }
    println("Use this address as TONTINE_USDT_MASTER for TontineCircle.");
    println("============================================================");
}
