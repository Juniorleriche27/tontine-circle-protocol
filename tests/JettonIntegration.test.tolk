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
    usdtWallet: address?,
    usdtMaster: address,
    protocolTreasury: address,
    circleWalletResolved: bool = true,
): TontineCircle {
    val contract = TontineCircle.fromStorage({
        circleId: 100,
        controller,
        usdtWallet,
        protocolState: (ProtocolState {
            jettonMasterConfig: (JettonMasterConfig {
                usdtMaster,
                protocolTreasury,
                circleWalletLookupPending: false,
                circleWalletResolved,
                circleWalletQueryId: 0,
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

    // Deploy circle with unresolved wallet
    val circle = setupIntegrationCircle(
        controller.address,
        null,
        minter.address,
        treasury.address,
        false,
    );

    val circleWalletAddress = minter.getWalletAddress(circle.address);
    val circleWallet = JettonWallet.fromAddress(circleWalletAddress);

    // Resolve circle's canonical Jetton wallet trustlessly via real JettonMinter
    val circleResolveTrace = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52434A57, 32).storeUint(10, 64).endCell(),
        { value: grams("0.2") }
    );
    expect(circleResolveTrace).toHaveSuccessfulTx({ from: controller.address, to: circle.address });
    expect(circleResolveTrace).toHaveSuccessfulTx({ from: circle.address, to: minter.address });
    expect(circleResolveTrace).toHaveSuccessfulTx({ from: minter.address, to: circle.address });

    expect(circle.circleJettonWalletResolved()).toBeTrue();
    expect(circle.circleJettonWallet()).toEqual(circleWalletAddress);

    mintJettons(minter, minterAdmin, circle.address, 1000000000);

    populateCircle(circle, controller, alice, bob, circleWallet);

    // Prepare payout for round 1 (strictly sequential queryId 1)
    val prep = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x50524550, 32).storeUint(1, 64).endCell(),
        { value: grams("0.1") }
    );
    expect(prep).toHaveSuccessfulTx({ from: controller.address, to: circle.address });

    // Resolve beneficiary Jetton wallet via real JettonMinter
    val resolveTxList = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52534C56, 32).storeUint(1, 64).endCell(),
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

    // Deploy Circle contract with unresolved usdtWallet
    val circle = setupIntegrationCircle(
        controller.address,
        null,
        minter.address,
        treasury.address,
        false,
    );

    // Canonical Circle Jetton wallet address from minter
    val circleWalletAddress = minter.getWalletAddress(circle.address);
    val circleWallet = JettonWallet.fromAddress(circleWalletAddress);

    // Resolve circle's canonical Jetton wallet trustlessly via real JettonMinter
    val circleResolveTrace = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52434A57, 32).storeUint(10, 64).endCell(),
        { value: grams("0.2") }
    );
    expect(circleResolveTrace).toHaveSuccessfulTx({ from: controller.address, to: circle.address });
    expect(circleResolveTrace).toHaveSuccessfulTx({ from: circle.address, to: minter.address });
    expect(circleResolveTrace).toHaveSuccessfulTx({ from: minter.address, to: circle.address });
    expect(circle.circleJettonWalletResolved()).toBeTrue();
    expect(circle.circleJettonWallet()).toEqual(circleWalletAddress);

    // Mint 1000 USDT to circle's wallet using real Minter (auto-deploys canonical wallet)
    mintJettons(minter, minterAdmin, circle.address, 1000000000);
    expect(circleWallet.getWalletData().jettonBalance).toEqual(1000000000);

    // Canonical Alice Jetton wallet
    val expectedAliceWallet = minter.getWalletAddress(alice.address);
    val aliceWallet = JettonWallet.fromAddress(expectedAliceWallet);

    populateCircle(circle, controller, alice, bob, circleWallet);

    // 1. Prepare Payout (queryId 1)
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x50524550, 32).storeUint(1, 64).endCell(),
        { value: grams("0.1") }
    );

    // 2. Resolve wallet through real JettonMinter
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52534C56, 32).storeUint(1, 64).endCell(),
        { value: grams("0.15") }
    );
    expect(circle.payoutBeneficiaryWalletResolved()).toBeTrue();

    // 3. Dispatch payout: 55 USDT net payout
    val dispatchTrace = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x44495350, 32).storeUint(1, 64).endCell(),
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

// ==================================================================
// CHANTIER 4: GENUINE TVM EMULATOR BOUNCE ON REAL JETTON WALLET
// ==================================================================

get fun `test integration: genuine TVM emulator bounce on real JettonWallet balance error resets payout dispatch`() {
    val controller = testing.treasury("real-b-ctrl");
    val alice = testing.treasury("real-b-alice");
    val bob = testing.treasury("real-b-bob");
    val treasury = testing.treasury("real-b-treasury");
    val minterAdmin = testing.treasury("real-b-minter-admin");

    val minter = deployMinter(minterAdmin.address);

    val circle = setupIntegrationCircle(
        controller.address,
        null,
        minter.address,
        treasury.address,
        false,
    );

    val circleWalletAddress = minter.getWalletAddress(circle.address);
    val circleWallet = JettonWallet.fromAddress(circleWalletAddress);

    // Resolve circle's canonical Jetton wallet trustlessly via real JettonMinter
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52434A57, 32).storeUint(10, 64).endCell(),
        { value: grams("0.2") }
    );
    expect(circle.circleJettonWalletResolved()).toBeTrue();
    expect(circle.circleJettonWallet()).toEqual(circleWalletAddress);

    // Mint 1 token unit (0.000001 USDT) so circleWallet is deployed but has insufficient balance for 55 USDT payout
    mintJettons(minter, minterAdmin, circle.address, 1);
    expect(circleWallet.getWalletData().jettonBalance).toEqual(1);

    // Populate circle members, lock, activate round 1, fund contributions
    populateCircle(circle, controller, alice, bob, circleWallet);

    // 1. Prepare payout for round 1 (queryId 1)
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x50524550, 32).storeUint(1, 64).endCell(),
        { value: grams("0.1") }
    );

    // 2. Resolve beneficiary Jetton wallet via real JettonMinter
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52534C56, 32).storeUint(1, 64).endCell(),
        { value: grams("0.15") }
    );
    expect(circle.payoutBeneficiaryWalletResolved()).toBeTrue();

    // NOTICE: circleWallet has 0 Jettons balance.
    // Payout net amount is 55 USDT (55000000).
    // When DispatchPayout is called, circle sends AskToTransfer with bounce: BounceMode.Only256BitsOfBody.
    // circleWallet executes on TVM emulator: balance (0) < 55000000 -> throws Errors.BalanceError (47).
    // TVM emulator generates genuine bounce back to circle.address.
    // circle.onBouncedMessage receives the bounce and resets payoutDispatched = false!
    val dispatchTrace = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x44495350, 32).storeUint(1, 64).endCell(),
        { value: grams("0.5") }
    );

    // Check failed transaction on circleWallet due to insufficient balance (exitCode 47)
    expect(dispatchTrace).toHaveFailedTx({
        from: circle.address,
        to: circleWallet.address,
        exitCode: 47,
    });

    // Check successful bounce transaction received and handled by circle
    expect(dispatchTrace).toHaveSuccessfulTx({
        from: circleWallet.address,
        to: circle.address,
    });

    // State safely recovered: dispatched is false, timestamp is 0, payout still pending
    expect(circle.payoutDispatched()).toBeFalse();
    expect(circle.payoutDispatchedAt()).toEqual(0);
    expect(circle.payoutPending()).toBeTrue();

    // Now mint the required USDT to circle's wallet (account for 1 unit already present)
    mintJettons(minter, minterAdmin, circle.address, 1000000000 - 1);
    expect(circleWallet.getWalletData().jettonBalance).toEqual(1000000000);

    // Redispatch payout now succeeds!
    val redispatchTrace = circle.sendAny(
        controller.address,
        beginCell().storeUint(0x44495350, 32).storeUint(1, 64).endCell(),
        { value: grams("0.5") }
    );
    val aliceWalletAddress = minter.getWalletAddress(alice.address);
    val aliceWallet = JettonWallet.fromAddress(aliceWalletAddress);

    expect(redispatchTrace).toHaveSuccessfulTx({ from: circle.address, to: circleWallet.address });
    expect(redispatchTrace).toHaveSuccessfulTx({ from: circleWallet.address, to: aliceWallet.address });
    expect(redispatchTrace).toHaveSuccessfulTx({ from: aliceWallet.address, to: circle.address });

    expect(circle.memberBeneficiaryPaid(alice.address)).toBeTrue();
    expect(circle.payoutPending()).toBeFalse();
}

// ==================================================================
// CHANTIER 5: E2E INBOUND JETTON TRANSFER (BOND & CONTRIBUTION)
// ==================================================================

get fun `test integration: e2e inbound jetton transfer for bond funding and round contribution`() {
    val controller = testing.treasury("inbound-ctrl");
    val alice = testing.treasury("inbound-alice");
    val bob = testing.treasury("inbound-bob");
    val treasury = testing.treasury("inbound-treasury");
    val minterAdmin = testing.treasury("inbound-minter-admin");

    val minter = deployMinter(minterAdmin.address);

    val circle = setupIntegrationCircle(
        controller.address,
        null,
        minter.address,
        treasury.address,
        false,
    );

    val circleWalletAddress = minter.getWalletAddress(circle.address);
    val circleWallet = JettonWallet.fromAddress(circleWalletAddress);

    // Resolve circle's canonical Jetton wallet
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52434A57, 32).storeUint(10, 64).endCell(),
        { value: grams("0.2") }
    );
    expect(circle.circleJettonWalletResolved()).toBeTrue();

    // Register Alice in round 1
    circle.sendAddMember(controller.address, 1, alice.address, 1, { value: grams("0.1") });

    // Mint 100 USDT to Alice
    mintJettons(minter, minterAdmin, alice.address, 100000000);
    val aliceWalletAddress = minter.getWalletAddress(alice.address);
    val aliceWallet = JettonWallet.fromAddress(aliceWalletAddress);
    expect(aliceWallet.getWalletData().jettonBalance).toEqual(100000000);

    // Alice transfers 40 USDT bond to circle.address via her real JettonWallet:
    // AskToTransfer sent to aliceWallet -> sends InternalTransferStep to circleWallet -> sends TransferNotificationForRecipient to circle
    val bondTransferTrace = aliceWallet.sendAny(
        alice.address,
        beginCell()
            .storeUint(0x0f8a7ea5, 32)
            .storeUint(1, 64)
            .storeCoins(40000000)
            .storeAddress(circle.address)
            .storeAddress(alice.address)
            .storeUint(0, 1) // null custom_payload
            .storeCoins(grams("0.05")) // forward_ton_amount
            .storeBool(false) // forward_payload inline
            .endCell(),
        { value: grams("0.2") }
    );

    expect(bondTransferTrace).toHaveSuccessfulTx({ from: alice.address, to: aliceWallet.address });
    expect(bondTransferTrace).toHaveSuccessfulTx({ from: aliceWallet.address, to: circleWallet.address });
    expect(bondTransferTrace).toHaveSuccessfulTx({ from: circleWallet.address, to: circle.address });

    // Verify bond is credited on-chain
    expect(circle.memberBond(alice.address)).toEqual(40000000);
    expect(circle.memberStatus(alice.address)).toEqual(2); // 2 = FUNDED_BOND
    expect(circle.fundedBondCount()).toEqual(1);
    expect(circleWallet.getWalletData().jettonBalance).toEqual(40000000);
    expect(aliceWallet.getWalletData().jettonBalance).toEqual(60000000);

    // Register remaining 9 members and fund bonds
    val m3 = testing.treasury("inbound-m3");
    val m4 = testing.treasury("inbound-m4");
    val m5 = testing.treasury("inbound-m5");
    val m6 = testing.treasury("inbound-m6");
    val m7 = testing.treasury("inbound-m7");
    val m8 = testing.treasury("inbound-m8");
    val m9 = testing.treasury("inbound-m9");
    val m10 = testing.treasury("inbound-m10");

    circle.sendAddMember(controller.address, 2, bob.address, 2, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 3, m3.address, 3, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 4, m4.address, 4, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 5, m5.address, 5, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 6, m6.address, 6, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 7, m7.address, 7, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 8, m8.address, 8, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 9, m9.address, 9, { value: grams("0.1") });
    circle.sendAddMember(controller.address, 10, m10.address, 10, { value: grams("0.1") });

    circle.sendAny(circleWallet.address, makeJettonNotification(2, 40000000, bob.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(3, 40000000, m3.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(4, 40000000, m4.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(5, 40000000, m5.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(6, 40000000, m6.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(7, 40000000, m7.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(8, 40000000, m8.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(9, 40000000, m9.address), { value: grams("0.1") });
    circle.sendAny(circleWallet.address, makeJettonNotification(10, 40000000, m10.address), { value: grams("0.1") });

    // Lock circle and activate round 1
    circle.sendAny(controller.address, beginCell().storeUint(0x4C4F434B, 32).storeUint(100, 64).endCell(), { value: grams("0.1") });
    circle.sendAny(controller.address, beginCell().storeUint(0x41435456, 32).storeUint(101, 64).endCell(), { value: grams("0.1") });
    expect(circle.state()).toEqual(4); // 4 = ACTIVE

    // Alice pays round 1 contribution (20 USDT) via her real JettonWallet:
    val contribTransferTrace = aliceWallet.sendAny(
        alice.address,
        beginCell()
            .storeUint(0x0f8a7ea5, 32)
            .storeUint(2, 64)
            .storeCoins(20000000)
            .storeAddress(circle.address)
            .storeAddress(alice.address)
            .storeUint(0, 1) // null custom_payload
            .storeCoins(grams("0.05")) // forward_ton_amount
            .storeBool(false) // forward_payload inline
            .endCell(),
        { value: grams("0.2") }
    );

    expect(contribTransferTrace).toHaveSuccessfulTx({ from: alice.address, to: aliceWallet.address });
    expect(contribTransferTrace).toHaveSuccessfulTx({ from: aliceWallet.address, to: circleWallet.address });
    expect(contribTransferTrace).toHaveSuccessfulTx({ from: circleWallet.address, to: circle.address });

    // Verify contribution is credited on-chain in TontineCircle!
    expect(circle.memberTotalContributed(alice.address)).toEqual(20000000);
    expect(circle.roundCollected()).toEqual(20000000);
    expect(circle.roundContributionCount()).toEqual(1);
    expect(aliceWallet.getWalletData().jettonBalance).toEqual(40000000);
}

// ==================================================================
// CHANTIER 6: DYNAMIC LIABILITIES VS REAL JETTON BALANCE SOLVENCY
// ==================================================================

// Ce test d'intégration valide la solvabilité comptable globale du contrat :
// - Le pool est initialement pré-financé à hauteur de 2400 USDT (400 cautions + 2000 cotisations)
//   directement émis sur le JettonWallet officiel du cercle (`circleWallet`).
// - Les 10 paiements de tour (payouts) exécutent de véritables transferts Jetton TEP-74
//   sur l'émulateur TVM vers les wallets bénéficiaires résolus par le Minter officiel.
// - Les cotisations intermédiaires des tours sont transmises via notifications de transfert
//   émises depuis l'adresse authentifiée du `circleWallet`. (Le flux entrant complet depuis
//   un JettonWallet membre individuel est validé par le test E2E dédié).
// - En fin de cycle (état COMPLETED), la somme dynamique des passifs calculée à partir des
//   getters du contrat (400 cautions + 560 séquestres + 50 frais = 1010 USDT) concorde
//   strictement avec le solde Jetton résiduel effectif du `circleWallet` (1010 USDT).
get fun `test integration: prefunded real jetton balance matches liabilities after ten real payouts`() {
    val controller = testing.treasury("solv-ctrl");
    val alice = testing.treasury("solv-alice");
    val bob = testing.treasury("solv-bob");
    val treasury = testing.treasury("solv-treasury");
    val minterAdmin = testing.treasury("solv-minter-admin");

    val minter = deployMinter(minterAdmin.address);

    val circle = setupIntegrationCircle(
        controller.address,
        null,
        minter.address,
        treasury.address,
        false,
    );

    val circleWalletAddress = minter.getWalletAddress(circle.address);
    val circleWallet = JettonWallet.fromAddress(circleWalletAddress);

    // Resolve circle's canonical Jetton wallet
    circle.sendAny(
        controller.address,
        beginCell().storeUint(0x52434A57, 32).storeUint(10, 64).endCell(),
        { value: grams("0.2") }
    );
    expect(circle.circleJettonWalletResolved()).toBeTrue();

    // Populate circle members, lock, activate round 1, fund contributions
    populateCircle(circle, controller, alice, bob, circleWallet);

    // Mint 2400 USDT total pool (400 bonds + 2000 round contributions) to circleWallet
    mintJettons(minter, minterAdmin, circle.address, 2400000000);
    expect(circleWallet.getWalletData().jettonBalance).toEqual(2400000000);

    // Complete rounds 1 to 10 payouts
    val master = minter;
    var round: uint8 = 1;
    while (round <= 10) {
        val qId: uint64 = round as uint64;
        val prepRes = circle.sendAny(controller.address, beginCell().storeUint(0x50524550, 32).storeUint(qId, 64).endCell(), { value: grams("0.1") });
        expect(prepRes).toHaveSuccessfulTx({ from: controller.address, to: circle.address });

        // Resolve payout wallet via real JettonMinter
        val resolveTx = circle.sendAny(controller.address, beginCell().storeUint(0x52534C56, 32).storeUint(qId, 64).endCell(), { value: grams("0.15") });
        expect(resolveTx).toHaveSuccessfulTx({ from: master.address, to: circle.address });

        // Dispatch payout with full gas to execute: circle -> circleWallet -> beneficiaryWallet -> circle (excess return)
        val dispatchTrace = circle.sendAny(controller.address, beginCell().storeUint(0x44495350, 32).storeUint(qId, 64).endCell(), { value: grams("0.5") });
        expect(dispatchTrace).toHaveSuccessfulTx({ from: controller.address, to: circle.address });

        if (round < 10) {
            // Fund next round contributions
            val m3 = testing.treasury("int-member-3");
            val m4 = testing.treasury("int-member-4");
            val m5 = testing.treasury("int-member-5");
            val m6 = testing.treasury("int-member-6");
            val m7 = testing.treasury("int-member-7");
            val m8 = testing.treasury("int-member-8");
            val m9 = testing.treasury("int-member-9");
            val m10 = testing.treasury("int-member-10");

            val baseQ: uint64 = (round as uint64) * 100;
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 1, 20000000, alice.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 2, 20000000, bob.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 3, 20000000, m3.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 4, 20000000, m4.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 5, 20000000, m5.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 6, 20000000, m6.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 7, 20000000, m7.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 8, 20000000, m8.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 9, 20000000, m9.address), { value: grams("0.05") });
            circle.sendAny(circleWallet.address, makeJettonNotification(baseQ + 10, 20000000, m10.address), { value: grams("0.05") });
        }

        round += 1;
    }

    expect(circle.state()).toEqual(5); // COMPLETED

    // Calculate dynamic liabilities dynamically from getters:
    val m3 = testing.treasury("int-member-3");
    val m4 = testing.treasury("int-member-4");
    val m5 = testing.treasury("int-member-5");
    val m6 = testing.treasury("int-member-6");
    val m7 = testing.treasury("int-member-7");
    val m8 = testing.treasury("int-member-8");
    val m9 = testing.treasury("int-member-9");
    val m10 = testing.treasury("int-member-10");

    val totalMemberLiabilities: uint64 =
        circle.memberSettlementDue(alice.address)
        + circle.memberSettlementDue(bob.address)
        + circle.memberSettlementDue(m3.address)
        + circle.memberSettlementDue(m4.address)
        + circle.memberSettlementDue(m5.address)
        + circle.memberSettlementDue(m6.address)
        + circle.memberSettlementDue(m7.address)
        + circle.memberSettlementDue(m8.address)
        + circle.memberSettlementDue(m9.address)
        + circle.memberSettlementDue(m10.address);

    expect(totalMemberLiabilities).toEqual(960000000); // 960 USDT
    expect(circle.protocolFeesAccrued()).toEqual(50000000); // 50 USDT

    val totalRequiredReserves: uint64 = totalMemberLiabilities + circle.protocolFeesAccrued();
    expect(totalRequiredReserves).toEqual(1010000000); // 1010 USDT

    // The real Jetton balance after 1390 USDT in real payouts deducted from 2400 USDT:
    val realJettonBalance = circleWallet.getWalletData().jettonBalance;
    expect(totalRequiredReserves).toEqual(realJettonBalance);
    expect(realJettonBalance).toEqual(1010000000);
}
