import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@wrappers/TontineCircle.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "../contracts/tontineTypes"
import "../contracts/jetton/storage"
import "../contracts/jetton/messages"

fun buildMetadata(uri: string): cell {
    var metadata: OnchainMetadataReply = { contentDict: [] };
    metadata.contentDict.set("uri".sha256(), uri.prefixWith00());
    return metadata.toCell();
}

fun deployMinter(admin: address): JettonMinter {
    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: admin,
        metadata: buildMetadata("https://tontine.finance/usdt.json"),
        nextAdminAddress: null,
    });
    val deployRes = minter.deploy(admin, { value: grams("5") });
    expect(deployRes).toHaveSuccessfulDeploy({ to: minter.address });
    return minter;
}

fun mintJettons(
    minter: JettonMinter,
    admin: Treasury,
    recipient: address,
    amount: coins,
) {
    val internalMsg = beginCell()
        .storeUint(0x178d4519, 32)
        .storeUint(1, 64)
        .storeCoins(amount)
        .storeAddress(admin.address)
        .storeAddress(admin.address)
        .storeCoins(0)
        .storeUint(0, 1)
        .endCell();

    minter.sendAny(
        admin.address,
        beginCell()
            .storeUint(0x642b7d07, 32)
            .storeUint(1, 64)
            .storeAddress(recipient)
            .storeCoins(grams("0.2"))
            .storeRef(internalMsg)
            .endCell(),
        { value: grams("0.5") }
    );
}

fun deployWallet(owner: address, minter: address, initialBalance: coins = 0): JettonWallet {
    val wallet = JettonWallet.fromStorage({
        jettonBalance: initialBalance,
        ownerAddress: owner,
        minterAddress: minter,
    });
    val deployRes = wallet.deploy(owner, { value: grams("5") });
    expect(deployRes).toHaveSuccessfulDeploy({ to: wallet.address });
    return wallet;
}

fun setupIntegrationCircle(
    controller: address,
    usdtWallet: address,
    usdtMaster: address,
    protocolTreasury: address,
): TontineCircle {
    val contract = TontineCircle.fromStorage({
        circleId: 100,
        controller,
        usdtWallet,
        protocolState: (ProtocolState {
            jettonMasterConfig: (JettonMasterConfig {
                usdtMaster,
                protocolTreasury,
            }).toCell(),
            settlement: (SettlementState {
                settlementPending: false,
                walletLookupPending: false,
                settlementDispatched: false,
                settlementDispatchedAt: 0,
                memberAddress: null,
                memberJettonWallet: null,
                amount: 0,
                queryId: 0,
            }).toCell(),
            feeState: (ProtocolFeeState {
                withdrawalPending: false,
                walletLookupPending: false,
                withdrawalDispatched: false,
                withdrawalDispatchedAt: 0,
                treasuryJettonWallet: null,
                amount: 0,
                queryId: 0,
            }).toCell(),
            memberSettlementsCompleted: 0,
            lastOperationQueryId: 0,
        }).toCell(),
        state: 1, // OPEN
        currentRound: 0,
        memberCount: 10,
        registeredCount: 0,
        fundedBondCount: 0,
        roundContributionCount: 0,
        roundCollected: 0,
        payout: (PayoutState {
            payoutPending: false,
            payoutDispatched: false,
            payoutDispatchedAt: 0,
            beneficiaryWalletLookupPending: false,
            beneficiaryJettonWallet: null,
            pendingPayoutRound: 0,
            pendingPayoutAmount: 0,
            pendingPayoutEscrow: 0,
            pendingPayoutFee: 0,
            pendingPayoutQueryId: 0,
            protocolFeesAccrued: 0,
        }).toCell(),
        contributionAmount: 20000000,
        personalBond: 40000000,
        protocolFeeBps: 250,
        members: [],
        roundOwners: [],
    });

    val deployResult = contract.deploy(controller, { value: grams("2") });
    expect(deployResult).toHaveSuccessfulDeploy({ to: contract.address });
    return contract;
}

fun makeJettonNotification(
    queryId: uint64,
    amount: coins,
    transferInitiator: address,
): cell {
    return beginCell()
        .storeUint(0x7362d09c, 32)
        .storeUint(queryId, 64)
        .storeCoins(amount)
        .storeAddress(transferInitiator)
        .storeBool(false)
        .endCell();
}

fun populateCircle(
    contract: TontineCircle,
    controller: Treasury,
    alice: Treasury,
    bob: Treasury,
    circleWallet: JettonWallet,
) {
    contract.sendAddMember(controller.address, 1, alice.address, 1);
    contract.sendAddMember(controller.address, 2, bob.address, 2);

    val m3 = testing.treasury("int-member-3");
    val m4 = testing.treasury("int-member-4");
    val m5 = testing.treasury("int-member-5");
    val m6 = testing.treasury("int-member-6");
    val m7 = testing.treasury("int-member-7");
    val m8 = testing.treasury("int-member-8");
    val m9 = testing.treasury("int-member-9");
    val m10 = testing.treasury("int-member-10");

    contract.sendAddMember(controller.address, 3, m3.address, 3);
    contract.sendAddMember(controller.address, 4, m4.address, 4);
    contract.sendAddMember(controller.address, 5, m5.address, 5);
    contract.sendAddMember(controller.address, 6, m6.address, 6);
    contract.sendAddMember(controller.address, 7, m7.address, 7);
    contract.sendAddMember(controller.address, 8, m8.address, 8);
    contract.sendAddMember(controller.address, 9, m9.address, 9);
    contract.sendAddMember(controller.address, 10, m10.address, 10);

    // Fund 10 bonds
    contract.sendAny(circleWallet.address, makeJettonNotification(1, 40000000, alice.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(2, 40000000, bob.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(3, 40000000, m3.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(4, 40000000, m4.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(5, 40000000, m5.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(6, 40000000, m6.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(7, 40000000, m7.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(8, 40000000, m8.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(9, 40000000, m9.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(10, 40000000, m10.address), { value: grams("0.1") });

    // Lock and activate
    contract.sendAny(controller.address, beginCell().storeUint(0x4C4F434B, 32).storeUint(100, 64).endCell(), { value: grams("0.1") });
    contract.sendAny(controller.address, beginCell().storeUint(0x41435456, 32).storeUint(101, 64).endCell(), { value: grams("0.1") });

    // Round 1 contributions
    contract.sendAny(circleWallet.address, makeJettonNotification(201, 20000000, alice.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(202, 20000000, bob.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(203, 20000000, m3.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(204, 20000000, m4.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(205, 20000000, m5.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(206, 20000000, m6.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(207, 20000000, m7.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(208, 20000000, m8.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(209, 20000000, m9.address), { value: grams("0.1") });
    contract.sendAny(circleWallet.address, makeJettonNotification(210, 20000000, m10.address), { value: grams("0.1") });
}


// ============================================================
// INTEGRATION TESTS WITH REAL JETTON MINTER & WALLET CONTRACTS
// ============================================================

get fun `test integration: minter deploys and calculates wallet addresses`() {
    val deployer = testing.treasury("deployer-jetton");
    val alice = testing.treasury("alice-jetton");

    val minter = deployMinter(deployer.address);
    val aliceWalletAddr = minter.getWalletAddress(alice.address);

    expect(aliceWalletAddr as any_address).toBeInternalAddress();
}

get fun `test integration: circle resolves beneficiary wallet through real JettonMinter`() {
    val controller = testing.treasury("int-ctrl-1");
    val alice = testing.treasury("int-alice-1");
    val bob = testing.treasury("int-bob-1");
    val treasury = testing.treasury("int-treasury-1");
    val minterAdmin = testing.treasury("int-minter-admin-1");

    val minter = deployMinter(minterAdmin.address);
    val expectedAliceWallet = minter.getWalletAddress(alice.address);

    // Temp placeholder for circle wallet
    val dummyCircleWallet = testing.treasury("dummy-circle-wallet");

    val circle = setupIntegrationCircle(
        controller.address,
        dummyCircleWallet.address,
        minter.address,
        treasury.address,
    );

    val circleWalletAddress = minter.getWalletAddress(circle.address);
    val circleWallet = JettonWallet.fromAddress(circleWalletAddress);
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x53544A57, 32).storeUint(10, 64).storeAddress(circleWalletAddress).endCell(),
        { value: grams("0.1") }
    );
    mintJettons(minter, minterAdmin, circle.address, 1000000000);

    populateCircle(circle, controller, alice, bob, circleWallet);

    // Prepare payout for round 1
    val prep = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x50524550, 32).storeUint(1001, 64).endCell(),
        { value: grams("0.1") }
    );
    expect(prep).toHaveSuccessfulTx({ from: controller.address, to: circle.address });

    // Resolve beneficiary Jetton wallet via real JettonMinter
    val resolveTxList = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52534C56, 32).storeUint(1001, 64).endCell(),
        { value: grams("0.15") }
    );

    // Verify trace: circle -> minter (RequestWalletAddress) -> circle (ResponseWalletAddress)
    expect(resolveTxList).toHaveSuccessfulTx({
        from: controller.address,
        to: circle.address,
    });
    expect(resolveTxList).toHaveSuccessfulTx({
        from: circle.address,
        to: minter.address,
    });
    expect(resolveTxList).toHaveSuccessfulTx({
        from: minter.address,
        to: circle.address,
    });

    // The circle successfully resolved the beneficiary wallet to the official minter address!
    expect(circle.payoutBeneficiaryWalletResolved()).toBeTrue();
    expect(circle.payoutBeneficiaryWalletLookupPending()).toBeFalse();
    expect(circle.payoutBeneficiaryJettonWallet()).toEqual(expectedAliceWallet);
}

get fun `test integration: full payout dispatch and excess return with real Jetton contracts`() {
    val controller = testing.treasury("int-ctrl-2");
    val alice = testing.treasury("int-alice-2");
    val bob = testing.treasury("int-bob-2");
    val treasury = testing.treasury("int-treasury-2");
    val minterAdmin = testing.treasury("int-minter-admin-2");

    val minter = deployMinter(minterAdmin.address);

    // Deploy Circle contract with placeholder usdtWallet
    val dummyCircleWallet = testing.treasury("dummy-circle-wallet-2");
    val circle = setupIntegrationCircle(
        controller.address,
        dummyCircleWallet.address,
        minter.address,
        treasury.address,
    );

    // Canonical Circle Jetton wallet address from minter
    val circleWalletAddress = minter.getWalletAddress(circle.address);
    val circleWallet = JettonWallet.fromAddress(circleWalletAddress);

    // Configure the circle with its real canonical Jetton wallet
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x53544A57, 32).storeUint(10, 64).storeAddress(circleWalletAddress).endCell(),
        { value: grams("0.1") }
    );

    // Mint 1000 USDT to circle's wallet using real Minter (auto-deploys canonical wallet)
    mintJettons(minter, minterAdmin, circle.address, 1000000000);
    expect(circleWallet.getWalletData().jettonBalance).toEqual(1000000000);

    // Canonical Alice Jetton wallet
    val expectedAliceWallet = minter.getWalletAddress(alice.address);
    val aliceWallet = JettonWallet.fromAddress(expectedAliceWallet);

    populateCircle(circle, controller, alice, bob, circleWallet);

    // 1. Prepare Payout (queryId 1001)
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x50524550, 32).storeUint(1001, 64).endCell(),
        { value: grams("0.1") }
    );

    // 2. Resolve wallet through real JettonMinter
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52534C56, 32).storeUint(1001, 64).endCell(),
        { value: grams("0.15") }
    );
    expect(circle.payoutBeneficiaryWalletResolved()).toBeTrue();

    // 3. Dispatch payout: 55 USDT net payout
    val dispatchTrace = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x44495350, 32).storeUint(1001, 64).endCell(),
        { value: grams("0.5") }
    );

    // Verify trace of the dispatch:
    // circle -> circleWallet (AskToTransfer)
    // circleWallet -> aliceWallet (InternalTransferStep)
    // aliceWallet -> circle (ReturnExcessesBack)
    expect(dispatchTrace).toHaveSuccessfulTx({
        from: controller.address,
        to: circle.address,
    });
    expect(dispatchTrace).toHaveSuccessfulTx({
        from: circle.address,
        to: circleWallet.address,
    });
    expect(dispatchTrace).toHaveSuccessfulTx({
        from: circleWallet.address,
        to: aliceWallet.address,
    });
    expect(dispatchTrace).toHaveSuccessfulTx({
        from: aliceWallet.address,
        to: circle.address,
    });

    // 4. Verify end-to-end outcome:
    // Alice's real JettonWallet received exactly 55 USDT!
    expect(aliceWallet.getWalletData().jettonBalance).toEqual(55000000);

    // Circle's JettonWallet deducted exactly 55 USDT (1000 - 55 = 945 USDT)
    expect(circleWallet.getWalletData().jettonBalance).toEqual(1000000000 - 55000000);

    // Payout is fully confirmed on-chain in TontineCircle!
    expect(circle.memberBeneficiaryPaid(alice.address)).toBeTrue();
    expect(circle.payoutPending()).toBeFalse();
    expect(circle.payoutDispatched()).toBeFalse();
    expect(circle.currentRound()).toEqual(2);
}
