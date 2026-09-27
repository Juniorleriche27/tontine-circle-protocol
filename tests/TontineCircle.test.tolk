import "@stdlib/gas-payments"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@wrappers/TontineCircle.gen"
import "../contracts/tontineTypes"
import "@acton/types/transaction"
import "@acton/types/message"


fun setupTest(): (
    TontineCircle,
    Treasury,
    Treasury,
    Treasury,
    Treasury,
    Treasury,
    Treasury
) {
    val controller = testing.treasury("controller");
    val alice = testing.treasury("alice");
    val bob = testing.treasury("bob");
    val outsider = testing.treasury("outsider");

    // Simule le Jetton Wallet USDT appartenant au contrat.
    val usdtWallet = testing.treasury("usdtWallet");

    // Simule un faux Jetton Wallet.
    val fakeJettonWallet = testing.treasury("fakeJettonWallet");

    val contract = TontineCircle.fromStorage({
        circleId: 1,
        controller: controller.address,
        usdtWallet: usdtWallet.address,

        protocolState: (ProtocolState {
            jettonMasterConfig: JettonMasterConfig {
                usdtMaster:
                    testing.treasury("usdt-master").address,
                protocolTreasury:
                    testing.treasury("protocol-treasury").address,
            }.toCell(),

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

        // OPEN
        state: 1,
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

    val deployResult = contract.deploy(
        controller.address,
        { value: grams("1") }
    );

    expect(deployResult).toHaveSuccessfulDeploy({
        to: contract.address
    });

    return (
        contract,
        controller,
        alice,
        bob,
        outsider,
        usdtWallet,
        fakeJettonWallet
    );
}


// ------------------------------------------------------------------
// Construit manuellement un transfer_notification Jetton.
//
// transfer_notification#7362d09c
// query_id:uint64
// amount:(VarUInteger 16)
// sender:MsgAddress
// forward_payload:(Either Cell ^Cell)
//
// Le dernier bit false signifie : payload inline vide.
// ------------------------------------------------------------------

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


// ==================================================================
// TESTS ADD MEMBER
// ==================================================================




// ============================================================
// COMPLETE CURRENT ROUND PAYOUT
// ============================================================

fun completeCurrentRoundPayout(
    contract: TontineCircle,
    controller: Treasury,
    beneficiaryJettonWallet: Treasury,
    queryId: uint64,
) {
    val usdtMaster =
        testing.treasury("usdt-master");

    // 1. Prepare
    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(queryId),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // 2. Resolve beneficiary Jetton wallet
    val lookup = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(queryId),
        { value: grams("0.1") }
    );

    expect(lookup).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val lookupTx =
        lookup.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(lookupTx).toBeNotNull();

    val lookupBody =
        lookupTx!.loadBody<RequestWalletAddress>();

    val responseBody = ResponseWalletAddress {
        queryId,
        jettonWalletAddress:
            beneficiaryJettonWallet.address,
        ownerAddress: lookupBody.ownerAddress.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    // 3. Dispatch
    val dispatched = contract.sendAny(
        controller.address,
        makeDispatchPayoutMessage(queryId),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // 4. Authenticated TEP-74 excesses
    val excessesBody = ReturnExcessesBack {
        queryId,
    }.toCell();

    val confirmed = contract.sendAny(
        beneficiaryJettonWallet.address,
        excessesBody,
        { value: grams("0.01") }
    );

    expect(confirmed).toHaveSuccessfulTx({
        from: beneficiaryJettonWallet.address,
        to: contract.address,
    });
}

fun completeCircleForSettlement(
    contract: TontineCircle,
    controller: Treasury,
    alice: Treasury,
    bob: Treasury,
    usdtWallet: Treasury,
) {
    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-1"),
        3001,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-2"),
        3002,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-3"),
        3003,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-4"),
        3004,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-5"),
        3005,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-6"),
        3006,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-7"),
        3007,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-8"),
        3008,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-9"),
        3009,
    );

    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(
        contract,
        controller,
        testing.treasury("settlement-payout-wallet-10"),
        3010,
    );
}


fun completeMemberSettlement(
    contract: TontineCircle,
    member: Treasury,
    memberJettonWallet: Treasury,
    queryId: uint64,
    expectedAmount: uint64,
) {
    val usdtMaster =
        testing.treasury("usdt-master");

    // --------------------------------------------------------
    // 1. Begin settlement
    // --------------------------------------------------------

    val claim = contract.sendAny(
        member.address,
        makeBeginSettlementMessage(queryId),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: member.address,
        to: contract.address,
    });

    expect(
        contract.settlementAmount()
    ).toEqual(expectedAmount);

    // --------------------------------------------------------
    // 2. Resolve official Jetton wallet
    // --------------------------------------------------------

    val responseBody = ResponseWalletAddress {
        queryId,
        jettonWalletAddress:
            memberJettonWallet.address,
        ownerAddress: member.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // 3. Dispatch
    // --------------------------------------------------------

    val dispatched = contract.sendAny(
        member.address,
        makeDispatchSettlementMessage(queryId),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: member.address,
        to: contract.address,
    });

    val usdtWallet =
        testing.treasury("usdtWallet");

    val transferTx =
        dispatched.findTransaction<AskToTransfer>({
            from: contract.address,
            to: usdtWallet.address,
        });

    expect(transferTx).toBeNotNull();

    val transferBody =
        transferTx!.loadBody<AskToTransfer>();

    expect(
        transferBody.queryId
    ).toEqual(queryId);

    expect(
        transferBody.jettonAmount
    ).toEqual(expectedAmount);

    expect(
        transferBody.transferRecipient
    ).toEqual(member.address);

    // --------------------------------------------------------
    // 4. Authenticated excesses
    // --------------------------------------------------------

    val excessesBody = ReturnExcessesBack {
        queryId,
    }.toCell();

    val confirmed = contract.sendAny(
        memberJettonWallet.address,
        excessesBody,
        { value: grams("0.01") }
    );

    expect(confirmed).toHaveSuccessfulTx({
        from: memberJettonWallet.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // 5. Member fully settled
    // --------------------------------------------------------

    expect(
        contract.memberBond(member.address)
    ).toEqual(0);

    expect(
        contract.memberEscrow(member.address)
    ).toEqual(0);

    expect(
        contract.memberSettlementDue(member.address)
    ).toEqual(0);

    expect(
        contract.settlementPending()
    ).toBeFalse();

    expect(
        contract.settlementDispatched()
    ).toBeFalse();
}


fun completeAllMemberSettlements(
    contract: TontineCircle,
    alice: Treasury,
    bob: Treasury,
) {
    val m3 = testing.treasury("member3");
    val m4 = testing.treasury("member4");
    val m5 = testing.treasury("member5");
    val m6 = testing.treasury("member6");
    val m7 = testing.treasury("member7");
    val m8 = testing.treasury("member8");
    val m9 = testing.treasury("member9");
    val m10 = testing.treasury("member10");

    completeMemberSettlement(
        contract,
        alice,
        testing.treasury("fees-final-wallet-alice"),
        5001,
        180000000,
    );

    completeMemberSettlement(
        contract,
        bob,
        testing.treasury("fees-final-wallet-bob"),
        5002,
        160000000,
    );

    completeMemberSettlement(
        contract,
        m3,
        testing.treasury("fees-final-wallet-m3"),
        5003,
        140000000,
    );

    completeMemberSettlement(
        contract,
        m4,
        testing.treasury("fees-final-wallet-m4"),
        5004,
        120000000,
    );

    completeMemberSettlement(
        contract,
        m5,
        testing.treasury("fees-final-wallet-m5"),
        5005,
        100000000,
    );

    completeMemberSettlement(
        contract,
        m6,
        testing.treasury("fees-final-wallet-m6"),
        5006,
        80000000,
    );

    completeMemberSettlement(
        contract,
        m7,
        testing.treasury("fees-final-wallet-m7"),
        5007,
        60000000,
    );

    completeMemberSettlement(
        contract,
        m8,
        testing.treasury("fees-final-wallet-m8"),
        5008,
        40000000,
    );

    completeMemberSettlement(
        contract,
        m9,
        testing.treasury("fees-final-wallet-m9"),
        5009,
        40000000,
    );

    completeMemberSettlement(
        contract,
        m10,
        testing.treasury("fees-final-wallet-m10"),
        5010,
        40000000,
    );
}


get fun `test controller can add member`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        _,
        _
    ) = setupTest();

    val result = contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    expect(result).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(contract.registeredCount()).toEqual(1);
    expect(contract.memberExists(alice.address)).toBeTrue();

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(200000000);

    expect(contract.memberBond(alice.address)).toEqual(0);
    expect(contract.memberEscrow(alice.address)).toEqual(0);

    expect(contract.roundIsAssigned(1)).toBeTrue();
}


get fun `test same wallet cannot be added twice`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        _,
        _
    ) = setupTest();

    val first = contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    expect(first).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val second = contract.sendAddMember(
        controller.address,
        2,
        alice.address,
        2,
        { value: grams("0.1") }
    );

    expect(second).toHaveFailedTx<AddMember>({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.MemberAlreadyExists,
    });

    expect(contract.registeredCount()).toEqual(1);
    expect(contract.roundIsAssigned(2)).toBeFalse();
}


get fun `test same round cannot be assigned twice`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        _,
        _
    ) = setupTest();

    val first = contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        3,
        { value: grams("0.1") }
    );

    expect(first).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val second = contract.sendAddMember(
        controller.address,
        2,
        bob.address,
        3,
        { value: grams("0.1") }
    );

    expect(second).toHaveFailedTx<AddMember>({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.RoundAlreadyAssigned,
    });

    expect(contract.registeredCount()).toEqual(1);
    expect(contract.memberExists(bob.address)).toBeFalse();
}


get fun `test non controller cannot add member`() {
    val (
        contract,
        _,
        alice,
        _,
        outsider,
        _,
        _
    ) = setupTest();

    val result = contract.sendAddMember(
        outsider.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx<AddMember>({
        from: outsider.address,
        to: contract.address,
        exitCode: TontineErrors.NotController,
    });

    expect(contract.registeredCount()).toEqual(0);
    expect(contract.memberExists(alice.address)).toBeFalse();
}


get fun `test invalid round is rejected`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        _,
        _
    ) = setupTest();

    val result = contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        11,
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx<AddMember>({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidAssignedRound,
    });

    expect(contract.registeredCount()).toEqual(0);
}


// ==================================================================
// TESTS CAUTION USDT
// ==================================================================

get fun `test member can fund bond with 40 usdt`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        usdtWallet,
        _
    ) = setupTest();

    contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    val body = makeJettonNotification(
        1,
        40000000,
        alice.address,
    );

    val result = contract.sendAny(
        usdtWallet.address,
        body,
        { value: grams("0.1") }
    );

    expect(result).toHaveSuccessfulTx({
        from: usdtWallet.address,
        to: contract.address,
    });

    expect(contract.memberBond(alice.address)).toEqual(40000000);

    // 2 = FUNDED_BOND
    expect(contract.memberStatus(alice.address)).toEqual(2);
}


get fun `test fake jetton wallet cannot fund bond`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        _,
        fakeJettonWallet
    ) = setupTest();

    contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    val body = makeJettonNotification(
        2,
        40000000,
        alice.address,
    );

    val result = contract.sendAny(
        fakeJettonWallet.address,
        body,
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx({
        from: fakeJettonWallet.address,
        to: contract.address,
        exitCode: TontineErrors.UnauthorizedJettonWallet,
    });

    expect(contract.memberBond(alice.address)).toEqual(0);
}


get fun `test wrong bond amount is rejected`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        usdtWallet,
        _
    ) = setupTest();

    contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    val body = makeJettonNotification(
        3,
        39000000,
        alice.address,
    );

    val result = contract.sendAny(
        usdtWallet.address,
        body,
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx({
        from: usdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidBondAmount,
    });

    expect(contract.memberBond(alice.address)).toEqual(0);
}


get fun `test member cannot fund bond twice`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        usdtWallet,
        _
    ) = setupTest();

    contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    val firstBody = makeJettonNotification(
        4,
        40000000,
        alice.address,
    );

    val first = contract.sendAny(
        usdtWallet.address,
        firstBody,
        { value: grams("0.1") }
    );

    expect(first).toHaveSuccessfulTx({
        from: usdtWallet.address,
        to: contract.address,
    });

    val secondBody = makeJettonNotification(
        5,
        40000000,
        alice.address,
    );

    val second = contract.sendAny(
        usdtWallet.address,
        secondBody,
        { value: grams("0.1") }
    );

    expect(second).toHaveFailedTx({
        from: usdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.BondAlreadyFunded,
    });

    expect(contract.memberBond(alice.address)).toEqual(40000000);
}


// ==================================================================
// HELPERS — LOCK / ACTIVATE
// ==================================================================

fun makeLockCircleMessage(queryId: uint64): cell {
    return beginCell()
        .storeUint(0x4C4F434B, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun makeActivateCircleMessage(queryId: uint64): cell {
    return beginCell()
        .storeUint(0x41435456, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun registerRemainingMembers(
    contract: TontineCircle,
    controller: Treasury,
    alice: Treasury,
    bob: Treasury,
): (
    Treasury,
    Treasury,
    Treasury,
    Treasury,
    Treasury,
    Treasury,
    Treasury,
    Treasury
) {
    val m3 = testing.treasury("member3");
    val m4 = testing.treasury("member4");
    val m5 = testing.treasury("member5");
    val m6 = testing.treasury("member6");
    val m7 = testing.treasury("member7");
    val m8 = testing.treasury("member8");
    val m9 = testing.treasury("member9");
    val m10 = testing.treasury("member10");

    contract.sendAddMember(
        controller.address, 1, alice.address, 1,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 2, bob.address, 2,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 3, m3.address, 3,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 4, m4.address, 4,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 5, m5.address, 5,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 6, m6.address, 6,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 7, m7.address, 7,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 8, m8.address, 8,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 9, m9.address, 9,
        { value: grams("0.1") }
    );

    contract.sendAddMember(
        controller.address, 10, m10.address, 10,
        { value: grams("0.1") }
    );

    return (
        m3,
        m4,
        m5,
        m6,
        m7,
        m8,
        m9,
        m10
    );
}


fun fundBond(
    contract: TontineCircle,
    usdtWallet: Treasury,
    member: Treasury,
    queryId: uint64,
) {
    val body = makeJettonNotification(
        queryId,
        40000000,
        member.address,
    );

    contract.sendAny(
        usdtWallet.address,
        body,
        { value: grams("0.1") }
    );
}


// ==================================================================
// TEST — CERCLE INCOMPLET NE PEUT PAS ÊTRE LOCKED
// ==================================================================

get fun `test incomplete circle cannot be locked`() {
    val (
        contract,
        controller,
        alice,
        _,
        _,
        _,
        _
    ) = setupTest();

    contract.sendAddMember(
        controller.address,
        1,
        alice.address,
        1,
        { value: grams("0.1") }
    );

    val result = contract.sendAny(
        controller.address,
        makeLockCircleMessage(100),
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.CircleNotFullyRegistered,
    });

    expect(contract.state()).toEqual(1);
}


// ==================================================================
// TEST — 10 MEMBRES MAIS CAUTIONS INCOMPLÈTES
// ==================================================================

get fun `test circle with missing bonds cannot be locked`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val (
        m3,
        m4,
        m5,
        m6,
        m7,
        m8,
        m9,
        m10
    ) = registerRemainingMembers(
        contract,
        controller,
        alice,
        bob,
    );

    // Seulement 9 cautions sur 10.
    fundBond(contract, usdtWallet, alice, 201);
    fundBond(contract, usdtWallet, bob, 202);
    fundBond(contract, usdtWallet, m3, 203);
    fundBond(contract, usdtWallet, m4, 204);
    fundBond(contract, usdtWallet, m5, 205);
    fundBond(contract, usdtWallet, m6, 206);
    fundBond(contract, usdtWallet, m7, 207);
    fundBond(contract, usdtWallet, m8, 208);
    fundBond(contract, usdtWallet, m9, 209);

    expect(contract.registeredCount()).toEqual(10);
    expect(contract.fundedBondCount()).toEqual(9);

    val result = contract.sendAny(
        controller.address,
        makeLockCircleMessage(210),
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.BondsNotFullyFunded,
    });

    expect(contract.state()).toEqual(1);
}


// ==================================================================
// TEST — CERCLE COMPLET PEUT ÊTRE LOCKED
// ==================================================================

get fun `test fully funded circle can be locked`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val (
        m3,
        m4,
        m5,
        m6,
        m7,
        m8,
        m9,
        m10
    ) = registerRemainingMembers(
        contract,
        controller,
        alice,
        bob,
    );

    fundBond(contract, usdtWallet, alice, 301);
    fundBond(contract, usdtWallet, bob, 302);
    fundBond(contract, usdtWallet, m3, 303);
    fundBond(contract, usdtWallet, m4, 304);
    fundBond(contract, usdtWallet, m5, 305);
    fundBond(contract, usdtWallet, m6, 306);
    fundBond(contract, usdtWallet, m7, 307);
    fundBond(contract, usdtWallet, m8, 308);
    fundBond(contract, usdtWallet, m9, 309);
    fundBond(contract, usdtWallet, m10, 310);

    expect(contract.registeredCount()).toEqual(10);
    expect(contract.fundedBondCount()).toEqual(10);

    val result = contract.sendAny(
        controller.address,
        makeLockCircleMessage(311),
        { value: grams("0.1") }
    );

    expect(result).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // 3 = LOCKED
    expect(contract.state()).toEqual(3);
}


// ==================================================================
// TEST — LOCKED -> ACTIVE
// ==================================================================

get fun `test locked circle can be activated at round one`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val (
        m3,
        m4,
        m5,
        m6,
        m7,
        m8,
        m9,
        m10
    ) = registerRemainingMembers(
        contract,
        controller,
        alice,
        bob,
    );

    fundBond(contract, usdtWallet, alice, 401);
    fundBond(contract, usdtWallet, bob, 402);
    fundBond(contract, usdtWallet, m3, 403);
    fundBond(contract, usdtWallet, m4, 404);
    fundBond(contract, usdtWallet, m5, 405);
    fundBond(contract, usdtWallet, m6, 406);
    fundBond(contract, usdtWallet, m7, 407);
    fundBond(contract, usdtWallet, m8, 408);
    fundBond(contract, usdtWallet, m9, 409);
    fundBond(contract, usdtWallet, m10, 410);

    val lockResult = contract.sendAny(
        controller.address,
        makeLockCircleMessage(411),
        { value: grams("0.1") }
    );

    expect(lockResult).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val activateResult = contract.sendAny(
        controller.address,
        makeActivateCircleMessage(412),
        { value: grams("0.1") }
    );

    expect(activateResult).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // 4 = ACTIVE
    expect(contract.state()).toEqual(4);

    // Le cercle démarre obligatoirement au round 1.
    expect(contract.currentRound()).toEqual(1);
}


// ==================================================================
// HELPERS — PREPARATION D'UN CERCLE COMPLET
// ==================================================================

fun prepareLockedCircle(
    contract: TontineCircle,
    controller: Treasury,
    alice: Treasury,
    bob: Treasury,
    usdtWallet: Treasury,
) {
    val (
        m3,
        m4,
        m5,
        m6,
        m7,
        m8,
        m9,
        m10
    ) = registerRemainingMembers(
        contract,
        controller,
        alice,
        bob,
    );

    fundBond(contract, usdtWallet, alice, 501);
    fundBond(contract, usdtWallet, bob, 502);
    fundBond(contract, usdtWallet, m3, 503);
    fundBond(contract, usdtWallet, m4, 504);
    fundBond(contract, usdtWallet, m5, 505);
    fundBond(contract, usdtWallet, m6, 506);
    fundBond(contract, usdtWallet, m7, 507);
    fundBond(contract, usdtWallet, m8, 508);
    fundBond(contract, usdtWallet, m9, 509);
    fundBond(contract, usdtWallet, m10, 510);

    val lockResult = contract.sendAny(
        controller.address,
        makeLockCircleMessage(511),
        { value: grams("0.1") }
    );

    expect(lockResult).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });
}


fun prepareActiveCircle(
    contract: TontineCircle,
    controller: Treasury,
    alice: Treasury,
    bob: Treasury,
    usdtWallet: Treasury,
) {
    prepareLockedCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val activateResult = contract.sendAny(
        controller.address,
        makeActivateCircleMessage(512),
        { value: grams("0.1") }
    );

    expect(activateResult).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });
}


// ==================================================================
// TEST — COTISATION DE 20 USDT ACCEPTEE
// ==================================================================

get fun `test active member can contribute 20 usdt`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val body = makeJettonNotification(
        600,
        20000000,
        alice.address,
    );

    val result = contract.sendAny(
        usdtWallet.address,
        body,
        { value: grams("0.1") }
    );

    expect(result).toHaveSuccessfulTx({
        from: usdtWallet.address,
        to: contract.address,
    });

    expect(
        contract.memberTotalContributed(alice.address)
    ).toEqual(20000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.memberLastContributionRound(alice.address)
    ).toEqual(1);

    expect(
        contract.roundContributionCount()
    ).toEqual(1);

    expect(
        contract.roundCollected()
    ).toEqual(20000000);
}


// ==================================================================
// TEST — DOUBLE COTISATION REFUSEE
// ==================================================================

get fun `test member cannot contribute twice in same round`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val firstBody = makeJettonNotification(
        610,
        20000000,
        alice.address,
    );

    val first = contract.sendAny(
        usdtWallet.address,
        firstBody,
        { value: grams("0.1") }
    );

    expect(first).toHaveSuccessfulTx({
        from: usdtWallet.address,
        to: contract.address,
    });

    val secondBody = makeJettonNotification(
        611,
        20000000,
        alice.address,
    );

    val second = contract.sendAny(
        usdtWallet.address,
        secondBody,
        { value: grams("0.1") }
    );

    expect(second).toHaveFailedTx({
        from: usdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.ContributionAlreadyPaid,
    });

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.memberTotalContributed(alice.address)
    ).toEqual(20000000);

    expect(
        contract.roundContributionCount()
    ).toEqual(1);

    expect(
        contract.roundCollected()
    ).toEqual(20000000);
}


// ==================================================================
// TEST — MAUVAIS MONTANT REFUSE
// ==================================================================

get fun `test wrong contribution amount is rejected`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val body = makeJettonNotification(
        620,
        19000000,
        alice.address,
    );

    val result = contract.sendAny(
        usdtWallet.address,
        body,
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx({
        from: usdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidContributionAmount,
    });

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(200000000);

    expect(
        contract.roundContributionCount()
    ).toEqual(0);

    expect(
        contract.roundCollected()
    ).toEqual(0);
}


// ==================================================================
// TEST — PAS DE COTISATION AVANT ACTIVE
// ==================================================================

get fun `test contribution cannot be paid while circle is locked`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareLockedCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    // Le cercle est LOCKED mais pas encore ACTIVE.
    expect(contract.state()).toEqual(3);

    val body = makeJettonNotification(
        630,
        20000000,
        alice.address,
    );

    val result = contract.sendAny(
        usdtWallet.address,
        body,
        { value: grams("0.1") }
    );

    expect(result).toHaveFailedTx({
        from: usdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidState,
    });

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(200000000);

    expect(
        contract.roundContributionCount()
    ).toEqual(0);
}


// ==================================================================
// TEST — LES 10 MEMBRES FINANCENT COMPLETEMENT LE ROUND 1
// ==================================================================

get fun `test round one collects full 200 usdt pot`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    // Ces treasuries correspondent aux mêmes membres
    // enregistrés par prepareActiveCircle().
    val m3 = testing.treasury("member3");
    val m4 = testing.treasury("member4");
    val m5 = testing.treasury("member5");
    val m6 = testing.treasury("member6");
    val m7 = testing.treasury("member7");
    val m8 = testing.treasury("member8");
    val m9 = testing.treasury("member9");
    val m10 = testing.treasury("member10");

    val p1 = makeJettonNotification(701, 20000000, alice.address);
    val p2 = makeJettonNotification(702, 20000000, bob.address);
    val p3 = makeJettonNotification(703, 20000000, m3.address);
    val p4 = makeJettonNotification(704, 20000000, m4.address);
    val p5 = makeJettonNotification(705, 20000000, m5.address);
    val p6 = makeJettonNotification(706, 20000000, m6.address);
    val p7 = makeJettonNotification(707, 20000000, m7.address);
    val p8 = makeJettonNotification(708, 20000000, m8.address);
    val p9 = makeJettonNotification(709, 20000000, m9.address);
    val p10 = makeJettonNotification(710, 20000000, m10.address);

    contract.sendAny(
        usdtWallet.address,
        p1,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p2,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p3,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p4,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p5,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p6,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p7,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p8,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p9,
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        p10,
        { value: grams("0.1") }
    );

    expect(contract.roundContributionCount()).toEqual(10);
    expect(contract.roundCollected()).toEqual(200000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.memberRemainingDebt(bob.address)
    ).toEqual(180000000);

    expect(
        contract.memberRemainingDebt(m10.address)
    ).toEqual(180000000);
}


// ==================================================================
// HELPER — FINANCER COMPLETEMENT LE ROUND 1
// ==================================================================

fun fundFullRoundOne(
    contract: TontineCircle,
    usdtWallet: Treasury,
    alice: Treasury,
    bob: Treasury,
) {
    val m3 = testing.treasury("member3");
    val m4 = testing.treasury("member4");
    val m5 = testing.treasury("member5");
    val m6 = testing.treasury("member6");
    val m7 = testing.treasury("member7");
    val m8 = testing.treasury("member8");
    val m9 = testing.treasury("member9");
    val m10 = testing.treasury("member10");

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(801, 20000000, alice.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(802, 20000000, bob.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(803, 20000000, m3.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(804, 20000000, m4.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(805, 20000000, m5.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(806, 20000000, m6.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(807, 20000000, m7.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(808, 20000000, m8.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(809, 20000000, m9.address),
        { value: grams("0.1") }
    );

    contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(810, 20000000, m10.address),
        { value: grams("0.1") }
    );
}


// ==================================================================
// TEST — DEVIS DU BENEFICIAIRE DU ROUND 1
// ==================================================================

get fun `test round one payout quote is 140 escrow 5 fee 55 net`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    expect(
        contract.roundContributionCount()
    ).toEqual(10);

    expect(
        contract.roundCollected()
    ).toEqual(200000000);

    // Alice possède le tour 1.
    expect(
        contract.currentBeneficiary()
    ).toEqual(alice.address);

    // Dette après sa cotisation du round 1 :
    // 200 - 20 = 180
    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    // Escrow requis :
    // 180 - caution 40 = 140
    expect(
        contract.currentRequiredEscrow()
    ).toEqual(140000000);

    // Frais protocole :
    // 200 * 2.5 % = 5
    expect(
        contract.currentProtocolFee()
    ).toEqual(5000000);

    // Paiement net :
    // 200 - 140 - 5 = 55
    expect(
        contract.currentNetPayout()
    ).toEqual(55000000);

    // Le devis seul ne doit encore verrouiller aucun escrow.
    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(0);

    // La caution reste intacte.
    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);
}


// ==================================================================
// HELPER — PREPARE PAYOUT
// ==================================================================

fun makeDispatchSettlementMessage(
    queryId: uint64
): cell {
    return beginCell()
        .storeUint(0x4453544C, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun makeRetrySettlementWalletMessage(
    queryId: uint64
): cell {
    return beginCell()
        .storeUint(0x5253544C, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun makeRetryProtocolFeeWalletMessage(
    queryId: uint64
): cell {
    return beginCell()
        .storeUint(0x52465745, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun makeDispatchProtocolFeeWithdrawalMessage(
    queryId: uint64
): cell {
    return beginCell()
        .storeUint(0x44465745, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun makeBeginProtocolFeeWithdrawalMessage(
    queryId: uint64
): cell {
    return beginCell()
        .storeUint(0x46574545, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun makeBeginSettlementMessage(
    queryId: uint64
): cell {
    return beginCell()
        .storeUint(0x53455454, 32)
        .storeUint(queryId, 64)
        .endCell();
}


fun makePreparePayoutMessage(queryId: uint64): cell {
    return beginCell()
        .storeUint(0x50524550, 32)
        .storeUint(queryId, 64)
        .endCell();
}


// ==================================================================
// TEST — PREPARATION DU PAIEMENT ROUND 1
// ==================================================================

get fun `test prepare payout reserves 140 escrow 5 fee and 55 pending`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    expect(contract.payoutPending()).toBeFalse();
    expect(contract.memberEscrow(alice.address)).toEqual(0);
    expect(contract.protocolFeesAccrued()).toEqual(0);

    val result = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(900),
        { value: grams("0.1") }
    );

    expect(result).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // Le paiement passe en attente.
    expect(contract.payoutPending()).toBeTrue();

    // Il appartient bien au round 1.
    expect(contract.pendingPayoutRound()).toEqual(1);

    // 55 USDT seront réellement envoyés au bénéficiaire.
    expect(contract.pendingPayoutAmount()).toEqual(55000000);

    // 140 USDT sont désormais réservés comme escrow.
    expect(contract.pendingPayoutEscrow()).toEqual(140000000);
    expect(contract.memberEscrow(alice.address)).toEqual(140000000);

    // 5 USDT sont réservés comme frais protocole.
    expect(contract.pendingPayoutFee()).toEqual(5000000);
    expect(contract.protocolFeesAccrued()).toEqual(5000000);

    // Rien ne doit encore déclarer Alice comme payée.
    // Le transfert Jetton réel n'a pas encore été confirmé.
    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);
}


// ==================================================================
// TEST — IMPOSSIBLE DE PREPARER LE MEME PAIEMENT DEUX FOIS
// ==================================================================

get fun `test payout cannot be prepared twice`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val first = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(910),
        { value: grams("0.1") }
    );

    expect(first).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val second = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(911),
        { value: grams("0.1") }
    );

    expect(second).toHaveFailedTx({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.PayoutAlreadyPending,
    });

    // Le second appel ne doit rien modifier.
    expect(contract.payoutPending()).toBeTrue();
    expect(contract.pendingPayoutRound()).toEqual(1);
    expect(contract.pendingPayoutAmount()).toEqual(55000000);
    expect(contract.pendingPayoutEscrow()).toEqual(140000000);
    expect(contract.pendingPayoutFee()).toEqual(5000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(contract.protocolFeesAccrued()).toEqual(5000000);
}



// ============================================================
// DISPATCH PAYOUT
// ============================================================

fun makeDispatchPayoutMessage(queryId: uint64): cell {
    return beginCell()
        .storeUint(0x44495350, 32)
        .storeUint(queryId, 64)
        .endCell();
}


get fun `test dispatch payout sends 55 usdt jetton transfer`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(900),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeFalse();

    // Résolution obligatoire du wallet USDT
    // du bénéficiaire avant le dispatch.
    val master900 =
        testing.treasury("usdt-master");

    val beneficiaryWallet900 =
        testing.treasury(
            "resolved-beneficiary-wallet-900"
        );

    val lookup900 = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(900),
        { value: grams("0.1") }
    );

    expect(lookup900).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val response900 =
        ResponseWalletAddress {
            queryId: 900,
            jettonWalletAddress:
                beneficiaryWallet900.address,
            ownerAddress: alice.address.toCell(),
        }.toCell();

    val resolution900 = contract.sendAny(
        master900.address,
        response900,
        { value: grams("0.05") }
    );

    expect(resolution900).toHaveSuccessfulTx({
        from: master900.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeTrue();

    val dispatched = contract.sendAny(
        controller.address,
        makeDispatchPayoutMessage(900),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val transferTx =
        dispatched.findTransaction<AskToTransfer>({
            from: contract.address,
            to: usdtWallet.address,
        });

    expect(transferTx).toBeNotNull();

    val body = transferTx!.loadBody<AskToTransfer>();

    expect(body.queryId).toEqual(900);

    // 55 USDT avec 6 décimales.
    expect(body.jettonAmount).toEqual(55000000);

    expect(body.transferRecipient).toEqual(alice.address);
    expect(body.sendExcessesTo).toEqual(contract.address);

    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeTrue();

    // Escrow inchangé : le bénéficiaire n'est toujours pas finalisé.
    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.payoutDispatchedAt() > 0
    ).toBeTrue();

    // --------------------------------------------------------
    // Monitoring temporel uniquement :
    // aucun retry automatique n'est déclenché.
    // --------------------------------------------------------

    expect(
        contract.payoutDispatchStale()
    ).toBeFalse();

    val dispatchedAt =
        contract.payoutDispatchedAt();

    testing.setNow(
        (dispatchedAt + 3599) as uint32
    );

    expect(
        contract.payoutDispatchStale()
    ).toBeFalse();

    testing.setNow(
        (dispatchedAt + 3600) as uint32
    );

    expect(
        contract.payoutDispatchStale()
    ).toBeTrue();

    // Le flag stale est purement informatif.
    // L'état financier reste dispatched.
    expect(
        contract.payoutDispatched()
    ).toBeTrue();

}



// ============================================================
// PAYOUT BOUNCE
// ============================================================

get fun `test bounced payout transfer becomes dispatchable again`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(901),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // Résolution obligatoire du wallet USDT
    // du bénéficiaire avant le dispatch.
    val master901 =
        testing.treasury("usdt-master");

    val beneficiaryWallet901 =
        testing.treasury(
            "resolved-beneficiary-wallet-901"
        );

    val lookup901 = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(901),
        { value: grams("0.1") }
    );

    expect(lookup901).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val response901 =
        ResponseWalletAddress {
            queryId: 901,
            jettonWalletAddress:
                beneficiaryWallet901.address,
            ownerAddress: alice.address.toCell(),
        }.toCell();

    val resolution901 = contract.sendAny(
        master901.address,
        response901,
        { value: grams("0.05") }
    );

    expect(resolution901).toHaveSuccessfulTx({
        from: master901.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeTrue();

    val dispatched = contract.sendAny(
        controller.address,
        makeDispatchPayoutMessage(901),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeTrue();

    // Récupère exactement le message Jetton réellement envoyé.
    val transferTx =
        dispatched.findTransaction<AskToTransfer>({
            from: contract.address,
            to: usdtWallet.address,
        });

    expect(transferTx).toBeNotNull();

    val transferBody =
        transferTx!.loadBody<AskToTransfer>();

    // TON ajoute 0xffffffff devant le corps original
    // lorsqu'un message interne revient en bounce.
    val bouncedBody = beginCell()
        .storeUint(0xffffffff, 32)
        .storeSlice(
            transferBody.toCell().beginParse()
        )
        .endCell();

    val bouncedMessage = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: bouncedBody,
    }).bounced();

    testing.processSingleTraceStep(
        usdtWallet.address,
        bouncedMessage,
    );

    // Le payout reste réservé...
    expect(contract.payoutPending()).toBeTrue();

    // ...mais peut maintenant être renvoyé.
    expect(contract.payoutDispatched()).toBeFalse();

    // Aucun double mouvement comptable.
    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(5000000);
}



get fun `test authoritative usdt master is stored`() {
    val (
        contract,
        _,
        _,
        _,
        _,
        _,
        _
    ) = setupTest();

    val expectedMaster =
        testing.treasury("usdt-master");

    expect(
        contract.usdtMasterAddress()
    ).toEqual(expectedMaster.address);
}



// ============================================================
// WALLET RESOLUTION HELPER
// ============================================================

fun makeResolvePayoutWalletMessage(queryId: uint64): cell {
    return beginCell()
        .storeUint(0x52534C56, 32)
        .storeUint(queryId, 64)
        .endCell();
}



get fun `test authoritative master resolves beneficiary jetton wallet`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceUsdtWallet =
        testing.treasury("alice-usdt-wallet");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(902),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeFalse();

    // Demande de résolution.
    val lookup = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(902),
        { value: grams("0.1") }
    );

    expect(lookup).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val lookupTx =
        lookup.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(lookupTx).toBeNotNull();

    val lookupBody =
        lookupTx!.loadBody<RequestWalletAddress>();

    expect(lookupBody.queryId).toEqual(902);
    expect(lookupBody.ownerAddress).toEqual(alice.address);
    expect(lookupBody.includeOwnerAddress).toBeTrue();

    expect(
        contract.payoutBeneficiaryWalletLookupPending()
    ).toBeTrue();

    // Réponse du Master USDT enregistré.
    val responseBody = ResponseWalletAddress {
        queryId: 902,
        jettonWalletAddress: aliceUsdtWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val response = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(response).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeTrue();

    expect(
        contract.payoutBeneficiaryJettonWallet()
    ).toEqual(aliceUsdtWallet.address);

    // Aucun mouvement financier.
    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(5000000);
}



get fun `test bounced wallet lookup can be retried`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(903),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val lookup = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(903),
        { value: grams("0.1") }
    );

    expect(lookup).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletLookupPending()
    ).toBeTrue();

    val lookupTx =
        lookup.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(lookupTx).toBeNotNull();

    val lookupBody =
        lookupTx!.loadBody<RequestWalletAddress>();

    val bouncedBody = beginCell()
        .storeUint(0xffffffff, 32)
        .storeSlice(
            lookupBody.toCell().beginParse()
        )
        .endCell();

    val bouncedMessage = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: bouncedBody,
    }).bounced();

    testing.processSingleTraceStep(
        usdtMaster.address,
        bouncedMessage,
    );

    // Le lookup n'est plus bloqué.
    expect(
        contract.payoutBeneficiaryWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeFalse();

    // Une nouvelle résolution est maintenant autorisée.
    val retry = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(903),
        { value: grams("0.1") }
    );

    expect(retry).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletLookupPending()
    ).toBeTrue();

    // Aucun état financier n'a changé.
    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(5000000);
}



get fun `test payout cannot dispatch before beneficiary wallet resolution`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(904),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeFalse();

    val rejected = contract.sendAny(
        controller.address,
        makeDispatchPayoutMessage(904),
        { value: grams("0.15") }
    );

    expect(rejected).toHaveFailedTx({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.WalletNotResolved,
    });

    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeFalse();

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(5000000);
}



// ============================================================
// PAYOUT FINALIZATION
// ============================================================

get fun `test authenticated jetton excesses finalizes payout`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceUsdtWallet =
        testing.treasury("final-alice-usdt-wallet");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    // --------------------------------------------------------
    // Prepare
    // --------------------------------------------------------

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(905),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Resolve beneficiary wallet
    // --------------------------------------------------------

    val lookup = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(905),
        { value: grams("0.1") }
    );

    expect(lookup).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 905,
        jettonWalletAddress: aliceUsdtWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Dispatch 55 USDT
    // --------------------------------------------------------

    val dispatched = contract.sendAny(
        controller.address,
        makeDispatchPayoutMessage(905),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeTrue();
    expect(contract.memberBeneficiaryPaid(alice.address))
        .toBeFalse();

    // --------------------------------------------------------
    // Le wallet USDT officiel d'Alice renvoie excesses.
    // --------------------------------------------------------

    val excessesBody = ReturnExcessesBack {
        queryId: 905,
    }.toCell();

    val confirmed = contract.sendAny(
        aliceUsdtWallet.address,
        excessesBody,
        { value: grams("0.01") }
    );

    expect(confirmed).toHaveSuccessfulTx({
        from: aliceUsdtWallet.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Payout définitivement confirmé.
    // --------------------------------------------------------

    expect(
        contract.memberBeneficiaryPaid(alice.address)
    ).toBeTrue();

    expect(contract.payoutPending()).toBeFalse();
    expect(contract.payoutDispatched()).toBeFalse();

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeFalse();

    // Les réservations financières ne sont PAS débitées
    // une deuxième fois.
    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(5000000);

    // Le payout du round 1 ouvre atomiquement le round 2.
    expect(contract.currentRound()).toEqual(2);

    // Le cercle reste actif.
    expect(contract.state()).toEqual(4);

    // Le nouveau round repart avec une collecte vierge.
    expect(contract.roundContributionCount()).toEqual(0);
    expect(contract.roundCollected()).toEqual(0);
}


// ============================================================
// FAKE / MISMATCHED EXCESSES
// ============================================================

get fun `test forged or mismatched excesses cannot finalize payout`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceUsdtWallet =
        testing.treasury("secure-alice-usdt-wallet");

    val attacker =
        testing.treasury("fake-excesses-sender");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(906),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val lookup = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(906),
        { value: grams("0.1") }
    );

    expect(lookup).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 906,
        jettonWalletAddress: aliceUsdtWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    val dispatched = contract.sendAny(
        controller.address,
        makeDispatchPayoutMessage(906),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // 1. Faux wallet avec bon queryId.
    // --------------------------------------------------------

    val forgedBody = ReturnExcessesBack {
        queryId: 906,
    }.toCell();

    val forged = contract.sendAny(
        attacker.address,
        forgedBody,
        { value: grams("0.01") }
    );

    expect(forged).toHaveFailedTx({
        from: attacker.address,
        to: contract.address,
        exitCode: TontineErrors.UnauthorizedJettonWallet,
    });

    expect(
        contract.memberBeneficiaryPaid(alice.address)
    ).toBeFalse();

    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeTrue();

    // --------------------------------------------------------
    // 2. Bon wallet avec mauvais queryId.
    // --------------------------------------------------------

    val wrongQueryBody = ReturnExcessesBack {
        queryId: 999999,
    }.toCell();

    val wrongQuery = contract.sendAny(
        aliceUsdtWallet.address,
        wrongQueryBody,
        { value: grams("0.01") }
    );

    expect(wrongQuery).toHaveFailedTx({
        from: aliceUsdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.PayoutQueryMismatch,
    });

    // Toujours aucun faux paiement.
    expect(
        contract.memberBeneficiaryPaid(alice.address)
    ).toBeFalse();

    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeTrue();

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(180000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(5000000);
}



// ============================================================
// FULL 10-ROUND TONTINE
// ============================================================

get fun `test complete ten round tontine reaches completed state`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val m3 = testing.treasury("member3");
    val m4 = testing.treasury("member4");
    val m5 = testing.treasury("member5");
    val m6 = testing.treasury("member6");
    val m7 = testing.treasury("member7");
    val m8 = testing.treasury("member8");
    val m9 = testing.treasury("member9");
    val m10 = testing.treasury("member10");

    val payoutWallet1 =
        testing.treasury("payout-wallet-round-1");

    val payoutWallet2 =
        testing.treasury("payout-wallet-round-2");

    val payoutWallet3 =
        testing.treasury("payout-wallet-round-3");

    val payoutWallet4 =
        testing.treasury("payout-wallet-round-4");

    val payoutWallet5 =
        testing.treasury("payout-wallet-round-5");

    val payoutWallet6 =
        testing.treasury("payout-wallet-round-6");

    val payoutWallet7 =
        testing.treasury("payout-wallet-round-7");

    val payoutWallet8 =
        testing.treasury("payout-wallet-round-8");

    val payoutWallet9 =
        testing.treasury("payout-wallet-round-9");

    val payoutWallet10 =
        testing.treasury("payout-wallet-round-10");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    expect(contract.currentRound()).toEqual(1);
    expect(contract.state()).toEqual(4);


    // ========================================================
    // ROUND 1 — Alice
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    expect(contract.roundCollected()).toEqual(200000000);
    expect(contract.roundContributionCount()).toEqual(10);

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet1,
        1001,
    );

    expect(contract.memberBeneficiaryPaid(alice.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(2);
    expect(contract.state()).toEqual(4);
    expect(contract.roundCollected()).toEqual(0);
    expect(contract.roundContributionCount()).toEqual(0);


    // ========================================================
    // ROUND 2 — Bob
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet2,
        1002,
    );

    expect(contract.memberBeneficiaryPaid(bob.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(3);
    expect(contract.state()).toEqual(4);


    // ========================================================
    // ROUND 3 — member3
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet3,
        1003,
    );

    expect(contract.memberBeneficiaryPaid(m3.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(4);


    // ========================================================
    // ROUND 4 — member4
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet4,
        1004,
    );

    expect(contract.memberBeneficiaryPaid(m4.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(5);


    // ========================================================
    // ROUND 5 — member5
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet5,
        1005,
    );

    expect(contract.memberBeneficiaryPaid(m5.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(6);


    // ========================================================
    // ROUND 6 — member6
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet6,
        1006,
    );

    expect(contract.memberBeneficiaryPaid(m6.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(7);


    // ========================================================
    // ROUND 7 — member7
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet7,
        1007,
    );

    expect(contract.memberBeneficiaryPaid(m7.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(8);


    // ========================================================
    // ROUND 8 — member8
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet8,
        1008,
    );

    expect(contract.memberBeneficiaryPaid(m8.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(9);


    // ========================================================
    // ROUND 9 — member9
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet9,
        1009,
    );

    expect(contract.memberBeneficiaryPaid(m9.address))
        .toBeTrue();

    expect(contract.currentRound()).toEqual(10);
    expect(contract.state()).toEqual(4);


    // ========================================================
    // ROUND 10 — member10
    // ========================================================

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    expect(contract.roundCollected()).toEqual(200000000);
    expect(contract.roundContributionCount()).toEqual(10);

    completeCurrentRoundPayout(
        contract,
        controller,
        payoutWallet10,
        1010,
    );

    expect(contract.memberBeneficiaryPaid(m10.address))
        .toBeTrue();


    // ========================================================
    // CIRCLE COMPLETED
    // ========================================================

    // 5 = COMPLETED
    expect(contract.state()).toEqual(5);

    // Ne doit jamais devenir round 11.
    expect(contract.currentRound()).toEqual(10);

    expect(contract.roundCollected()).toEqual(0);
    expect(contract.roundContributionCount()).toEqual(0);

    expect(contract.payoutPending()).toBeFalse();
    expect(contract.payoutDispatched()).toBeFalse();

    // 10 rounds × 5 USDT de frais.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);


    // ========================================================
    // LES 10 MEMBRES ONT PAYE 10 × 20 USDT
    // ========================================================

    expect(
        contract.memberTotalContributed(alice.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(bob.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m3.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m4.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m5.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m6.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m7.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m8.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m9.address)
    ).toEqual(200000000);

    expect(
        contract.memberTotalContributed(m10.address)
    ).toEqual(200000000);


    // ========================================================
    // PLUS AUCUNE DETTE DE COTISATION
    // ========================================================

    expect(
        contract.memberRemainingDebt(alice.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(bob.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m3.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m4.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m5.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m6.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m7.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m8.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m9.address)
    ).toEqual(0);

    expect(
        contract.memberRemainingDebt(m10.address)
    ).toEqual(0);


    // ========================================================
    // LES 10 BENEFICIAIRES SONT MARQUES PAYES
    // ========================================================

    expect(contract.memberBeneficiaryPaid(alice.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(bob.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m3.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m4.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m5.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m6.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m7.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m8.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m9.address))
        .toBeTrue();

    expect(contract.memberBeneficiaryPaid(m10.address))
        .toBeTrue();




    // ========================================================
    // SETTLEMENT FINAL — CAUTION + ESCROW
    // ========================================================

    // Alice :
    // 40 USDT de caution + 140 USDT d'escrow.
    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);

    // Bob :
    // 40 + 120.
    expect(
        contract.memberSettlementDue(bob.address)
    ).toEqual(160000000);

    // member3 :
    // 40 + 100.
    expect(
        contract.memberSettlementDue(m3.address)
    ).toEqual(140000000);

    // member4 :
    // 40 + 80.
    expect(
        contract.memberSettlementDue(m4.address)
    ).toEqual(120000000);

    // member5 :
    // 40 + 60.
    expect(
        contract.memberSettlementDue(m5.address)
    ).toEqual(100000000);

    // member6 :
    // 40 + 40.
    expect(
        contract.memberSettlementDue(m6.address)
    ).toEqual(80000000);

    // member7 :
    // 40 + 20.
    expect(
        contract.memberSettlementDue(m7.address)
    ).toEqual(60000000);

    // member8 :
    // plus d'escrow requis à son payout.
    expect(
        contract.memberSettlementDue(m8.address)
    ).toEqual(40000000);

    expect(
        contract.memberSettlementDue(m9.address)
    ).toEqual(40000000);

    expect(
        contract.memberSettlementDue(m10.address)
    ).toEqual(40000000);

    // Total dû aux dix membres :
    // 960 USDT.
    val totalSettlementDue =
        contract.memberSettlementDue(alice.address)
        + contract.memberSettlementDue(bob.address)
        + contract.memberSettlementDue(m3.address)
        + contract.memberSettlementDue(m4.address)
        + contract.memberSettlementDue(m5.address)
        + contract.memberSettlementDue(m6.address)
        + contract.memberSettlementDue(m7.address)
        + contract.memberSettlementDue(m8.address)
        + contract.memberSettlementDue(m9.address)
        + contract.memberSettlementDue(m10.address);

    expect(totalSettlementDue).toEqual(960000000);

    // Les 50 USDT de frais restent séparés.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // ========================================================
    // COMPLETED = aucune nouvelle cotisation
    // ========================================================

    val afterCompletion = contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(
            9999,
            20000000,
            alice.address,
        ),
        { value: grams("0.1") }
    );

    expect(afterCompletion).toHaveFailedTx({
        from: usdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidState,
    });
}



// ============================================================
// FINAL SETTLEMENT — PHASE 1
// ============================================================

get fun `test completed member can begin settlement wallet resolution`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    expect(contract.state()).toEqual(5);

    // Alice doit récupérer :
    // 40 USDT bond + 140 USDT escrow.
    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);

    expect(contract.settlementPending())
        .toBeFalse();

    // --------------------------------------------------------
    // Alice initie elle-même son settlement.
    // --------------------------------------------------------

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4001),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Le contrat doit interroger le Master USDT officiel.
    // --------------------------------------------------------

    val lookupTx =
        claim.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(lookupTx).toBeNotNull();

    val lookupBody =
        lookupTx!.loadBody<RequestWalletAddress>();

    expect(lookupBody.queryId)
        .toEqual(4001);

    expect(lookupBody.ownerAddress)
        .toEqual(alice.address);

    expect(lookupBody.includeOwnerAddress)
        .toBeTrue();

    // --------------------------------------------------------
    // Etat figé.
    // --------------------------------------------------------

    expect(contract.settlementPending())
        .toBeTrue();

    expect(contract.settlementWalletLookupPending())
        .toBeTrue();

    expect(contract.settlementDispatched())
        .toBeFalse();

    expect(contract.settlementWalletResolved())
        .toBeFalse();

    expect(contract.settlementMember())
        .toEqual(alice.address);

    expect(contract.settlementAmount())
        .toEqual(180000000);

    // --------------------------------------------------------
    // Aucun actif comptable n'a encore été libéré.
    // --------------------------------------------------------

    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);
}



// ============================================================
// FINAL SETTLEMENT — WALLET RESOLUTION
// ============================================================

get fun `test authoritative master resolves settlement jetton wallet`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceSettlementWallet =
        testing.treasury("alice-settlement-usdt-wallet");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4002),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    expect(
        contract.settlementWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.settlementWalletResolved()
    ).toBeFalse();

    val responseBody = ResponseWalletAddress {
        queryId: 4002,
        jettonWalletAddress:
            aliceSettlementWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val response = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(response).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.settlementWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.settlementWalletResolved()
    ).toBeTrue();

    expect(
        contract.settlementJettonWallet()
    ).toEqual(aliceSettlementWallet.address);

    expect(
        contract.settlementAmount()
    ).toEqual(180000000);

    // Toujours aucun transfert ni libération comptable.
    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);
}



get fun `test fake master cannot resolve settlement jetton wallet`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val attacker =
        testing.treasury("fake-settlement-master");

    val fakeWallet =
        testing.treasury("fake-settlement-wallet");

    val realAliceWallet =
        testing.treasury("real-alice-settlement-wallet");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4003),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Un faux Master tente d'imposer son propre wallet.
    // --------------------------------------------------------

    val forgedResponse = ResponseWalletAddress {
        queryId: 4003,
        jettonWalletAddress: fakeWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val forged = contract.sendAny(
        attacker.address,
        forgedResponse,
        { value: grams("0.05") }
    );

    expect(forged).toHaveFailedTx({
        from: attacker.address,
        to: contract.address,
        exitCode: TontineErrors.UnauthorizedJettonWallet,
    });

    // Le faux message ne doit avoir modifié aucun état.
    expect(
        contract.settlementWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.settlementWalletResolved()
    ).toBeFalse();

    expect(
        contract.settlementAmount()
    ).toEqual(180000000);

    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    // --------------------------------------------------------
    // Le vrai Master peut toujours résoudre ensuite.
    // --------------------------------------------------------

    val realResponse = ResponseWalletAddress {
        queryId: 4003,
        jettonWalletAddress: realAliceWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        realResponse,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.settlementWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.settlementJettonWallet()
    ).toEqual(realAliceWallet.address);
}



// ============================================================
// FINAL SETTLEMENT — LOOKUP BOUNCE + RETRY
// ============================================================

get fun `test bounced settlement wallet lookup can be retried`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    // --------------------------------------------------------
    // Alice ouvre son settlement.
    // --------------------------------------------------------

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4004),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    expect(
        contract.settlementWalletLookupPending()
    ).toBeTrue();

    val lookupTx =
        claim.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(lookupTx).toBeNotNull();

    val lookupBody =
        lookupTx!.loadBody<RequestWalletAddress>();

    // --------------------------------------------------------
    // Le lookup vers le Master USDT bounce.
    // --------------------------------------------------------

    val bouncedBody = beginCell()
        .storeUint(0xffffffff, 32)
        .storeSlice(
            lookupBody.toCell().beginParse()
        )
        .endCell();

    val bouncedMessage = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: bouncedBody,
    }).bounced();

    testing.processSingleTraceStep(
        usdtMaster.address,
        bouncedMessage,
    );

    // --------------------------------------------------------
    // Le settlement reste ouvert,
    // mais le lookup n'est plus bloqué.
    // --------------------------------------------------------

    expect(
        contract.settlementPending()
    ).toBeTrue();

    expect(
        contract.settlementWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.settlementWalletResolved()
    ).toBeFalse();

    expect(
        contract.settlementAmount()
    ).toEqual(180000000);

    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    // --------------------------------------------------------
    // Bob ne peut pas relancer le settlement d'Alice.
    // --------------------------------------------------------

    val bobRetry = contract.sendAny(
        bob.address,
        makeRetrySettlementWalletMessage(4004),
        { value: grams("0.1") }
    );

    expect(bobRetry).toHaveFailedTx({
        from: bob.address,
        to: contract.address,
        exitCode: TontineErrors.SettlementMemberMismatch,
    });

    expect(
        contract.settlementWalletLookupPending()
    ).toBeFalse();

    // --------------------------------------------------------
    // Alice peut relancer avec le même queryId.
    // --------------------------------------------------------

    val retry = contract.sendAny(
        alice.address,
        makeRetrySettlementWalletMessage(4004),
        { value: grams("0.1") }
    );

    expect(retry).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    val retryLookupTx =
        retry.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(retryLookupTx).toBeNotNull();

    val retryLookupBody =
        retryLookupTx!.loadBody<RequestWalletAddress>();

    expect(
        retryLookupBody.queryId
    ).toEqual(4004);

    expect(
        retryLookupBody.ownerAddress
    ).toEqual(alice.address);

    expect(
        retryLookupBody.includeOwnerAddress
    ).toBeTrue();

    expect(
        contract.settlementWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.settlementWalletResolved()
    ).toBeFalse();

    // Toujours aucun mouvement financier.
    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);
}



// ============================================================
// FINAL SETTLEMENT — DISPATCH
// ============================================================

get fun `test settlement dispatch sends full bond and escrow`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceSettlementWallet =
        testing.treasury(
            "alice-settlement-dispatch-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4005),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 4005,
        jettonWalletAddress:
            aliceSettlementWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    val dispatched = contract.sendAny(
        alice.address,
        makeDispatchSettlementMessage(4005),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    val transferTx =
        dispatched.findTransaction<AskToTransfer>({
            from: contract.address,
            to: usdtWallet.address,
        });

    expect(transferTx).toBeNotNull();

    val transferBody =
        transferTx!.loadBody<AskToTransfer>();

    expect(transferBody.queryId)
        .toEqual(4005);

    expect(transferBody.jettonAmount)
        .toEqual(180000000);

    expect(transferBody.transferRecipient)
        .toEqual(alice.address);

    expect(transferBody.sendExcessesTo)
        .toEqual(contract.address);

    expect(
        contract.settlementDispatched()
    ).toBeTrue();

    // --------------------------------------------------------
    // Toujours rien libéré comptablement.
    // --------------------------------------------------------

    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);

    expect(
        contract.settlementDispatchedAt() > 0
    ).toBeTrue();

    // --------------------------------------------------------
    // Monitoring temporel uniquement :
    // aucun retry automatique n'est déclenché.
    // --------------------------------------------------------

    expect(
        contract.settlementDispatchStale()
    ).toBeFalse();

    val dispatchedAt =
        contract.settlementDispatchedAt();

    testing.setNow(
        (dispatchedAt + 3599) as uint32
    );

    expect(
        contract.settlementDispatchStale()
    ).toBeFalse();

    testing.setNow(
        (dispatchedAt + 3600) as uint32
    );

    expect(
        contract.settlementDispatchStale()
    ).toBeTrue();

    // Le flag stale est purement informatif.
    // L'état financier reste dispatched.
    expect(
        contract.settlementDispatched()
    ).toBeTrue();

}



get fun `test bounced settlement transfer becomes dispatchable again`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceSettlementWallet =
        testing.treasury(
            "alice-settlement-bounce-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4006),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 4006,
        jettonWalletAddress:
            aliceSettlementWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    val dispatched = contract.sendAny(
        alice.address,
        makeDispatchSettlementMessage(4006),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    expect(
        contract.settlementDispatched()
    ).toBeTrue();

    val transferTx =
        dispatched.findTransaction<AskToTransfer>({
            from: contract.address,
            to: usdtWallet.address,
        });

    expect(transferTx).toBeNotNull();

    val transferBody =
        transferTx!.loadBody<AskToTransfer>();

    val bouncedBody = beginCell()
        .storeUint(0xffffffff, 32)
        .storeSlice(
            transferBody.toCell().beginParse()
        )
        .endCell();

    val bouncedMessage = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: bouncedBody,
    }).bounced();

    testing.processSingleTraceStep(
        usdtWallet.address,
        bouncedMessage,
    );

    // --------------------------------------------------------
    // Le transfert a échoué :
    // le settlement reste ouvert.
    // --------------------------------------------------------

    expect(
        contract.settlementPending()
    ).toBeTrue();

    expect(
        contract.settlementDispatched()
    ).toBeFalse();

    expect(
        contract.settlementWalletResolved()
    ).toBeTrue();

    // Aucun actif comptable perdu.
    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);

    // --------------------------------------------------------
    // Alice peut redispatcher.
    // --------------------------------------------------------

    val retry = contract.sendAny(
        alice.address,
        makeDispatchSettlementMessage(4006),
        { value: grams("0.15") }
    );

    expect(retry).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    expect(
        contract.settlementDispatched()
    ).toBeTrue();
}



// ============================================================
// FINAL SETTLEMENT — AUTHENTICATED EXCESSES
// ============================================================

get fun `test authenticated settlement excesses releases bond and escrow`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceSettlementWallet =
        testing.treasury(
            "alice-final-settlement-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    // --------------------------------------------------------
    // Begin settlement.
    // --------------------------------------------------------

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4007),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Master officiel résout le wallet USDT d'Alice.
    // --------------------------------------------------------

    val responseBody = ResponseWalletAddress {
        queryId: 4007,
        jettonWalletAddress:
            aliceSettlementWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Dispatch des 180 USDT.
    // --------------------------------------------------------

    val dispatched = contract.sendAny(
        alice.address,
        makeDispatchSettlementMessage(4007),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    expect(
        contract.settlementDispatched()
    ).toBeTrue();

    // Avant confirmation :
    // rien n'est encore libéré.
    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    // --------------------------------------------------------
    // Le wallet USDT authentifié renvoie excesses.
    // --------------------------------------------------------

    val excessesBody = ReturnExcessesBack {
        queryId: 4007,
    }.toCell();

    val confirmed = contract.sendAny(
        aliceSettlementWallet.address,
        excessesBody,
        { value: grams("0.01") }
    );

    expect(confirmed).toHaveSuccessfulTx({
        from: aliceSettlementWallet.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Settlement définitivement terminé.
    // --------------------------------------------------------

    expect(
        contract.memberBond(alice.address)
    ).toEqual(0);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(0);

    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(0);

    expect(
        contract.settlementPending()
    ).toBeFalse();

    expect(
        contract.settlementDispatched()
    ).toBeFalse();

    expect(
        contract.settlementWalletResolved()
    ).toBeFalse();

    expect(
        contract.settlementAmount()
    ).toEqual(0);

    // --------------------------------------------------------
    // Alice ne peut pas réclamer une seconde fois.
    // --------------------------------------------------------

    val duplicateClaim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4008),
        { value: grams("0.1") }
    );

    expect(duplicateClaim).toHaveFailedTx({
        from: alice.address,
        to: contract.address,
        exitCode: TontineErrors.SettlementNothingToClaim,
    });

    // --------------------------------------------------------
    // La sérialisation est libérée :
    // Bob peut maintenant ouvrir son propre settlement.
    // --------------------------------------------------------

    expect(
        contract.memberSettlementDue(bob.address)
    ).toEqual(160000000);

    val bobClaim = contract.sendAny(
        bob.address,
        makeBeginSettlementMessage(4009),
        { value: grams("0.1") }
    );

    expect(bobClaim).toHaveSuccessfulTx({
        from: bob.address,
        to: contract.address,
    });

    expect(
        contract.settlementPending()
    ).toBeTrue();

    expect(
        contract.settlementMember()
    ).toEqual(bob.address);

    expect(
        contract.settlementAmount()
    ).toEqual(160000000);
}



get fun `test forged settlement excesses cannot release member funds`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val aliceSettlementWallet =
        testing.treasury(
            "secure-alice-final-wallet"
        );

    val attacker =
        testing.treasury(
            "fake-settlement-excesses-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4010),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 4010,
        jettonWalletAddress:
            aliceSettlementWallet.address,
        ownerAddress: alice.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    val dispatched = contract.sendAny(
        alice.address,
        makeDispatchSettlementMessage(4010),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // 1. Faux wallet avec le bon queryId.
    // --------------------------------------------------------

    val forgedBody = ReturnExcessesBack {
        queryId: 4010,
    }.toCell();

    val forged = contract.sendAny(
        attacker.address,
        forgedBody,
        { value: grams("0.01") }
    );

    expect(forged).toHaveFailedTx({
        from: attacker.address,
        to: contract.address,
        exitCode: TontineErrors.UnauthorizedJettonWallet,
    });

    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.settlementPending()
    ).toBeTrue();

    expect(
        contract.settlementDispatched()
    ).toBeTrue();

    // --------------------------------------------------------
    // 2. Bon wallet mais mauvais queryId.
    // --------------------------------------------------------

    val wrongQueryBody = ReturnExcessesBack {
        queryId: 999999,
    }.toCell();

    val wrongQuery = contract.sendAny(
        aliceSettlementWallet.address,
        wrongQueryBody,
        { value: grams("0.01") }
    );

    expect(wrongQuery).toHaveFailedTx({
        from: aliceSettlementWallet.address,
        to: contract.address,
        exitCode: TontineErrors.SettlementQueryMismatch,
    });

    // Toujours aucune libération frauduleuse.
    expect(
        contract.memberBond(alice.address)
    ).toEqual(40000000);

    expect(
        contract.memberEscrow(alice.address)
    ).toEqual(140000000);

    expect(
        contract.memberSettlementDue(alice.address)
    ).toEqual(180000000);

    expect(
        contract.settlementPending()
    ).toBeTrue();

    expect(
        contract.settlementDispatched()
    ).toBeTrue();
}



// ============================================================
// FULL FINAL SETTLEMENT — 10 MEMBERS
// ============================================================

get fun `test all ten members complete final settlement`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val m3 = testing.treasury("member3");
    val m4 = testing.treasury("member4");
    val m5 = testing.treasury("member5");
    val m6 = testing.treasury("member6");
    val m7 = testing.treasury("member7");
    val m8 = testing.treasury("member8");
    val m9 = testing.treasury("member9");
    val m10 = testing.treasury("member10");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    expect(contract.state()).toEqual(5);

    // ========================================================
    // Settlement 1 — Alice : 40 bond + 140 escrow = 180
    // ========================================================

    completeMemberSettlement(
        contract,
        alice,
        testing.treasury("final-wallet-alice"),
        5001,
        180000000,
    );

    // ========================================================
    // Settlement 2 — Bob : 40 + 120 = 160
    // ========================================================

    completeMemberSettlement(
        contract,
        bob,
        testing.treasury("final-wallet-bob"),
        5002,
        160000000,
    );

    // ========================================================
    // Settlement 3 — member3 : 40 + 100 = 140
    // ========================================================

    completeMemberSettlement(
        contract,
        m3,
        testing.treasury("final-wallet-m3"),
        5003,
        140000000,
    );

    // ========================================================
    // Settlement 4 — member4 : 40 + 80 = 120
    // ========================================================

    completeMemberSettlement(
        contract,
        m4,
        testing.treasury("final-wallet-m4"),
        5004,
        120000000,
    );

    // ========================================================
    // Settlement 5 — member5 : 40 + 60 = 100
    // ========================================================

    completeMemberSettlement(
        contract,
        m5,
        testing.treasury("final-wallet-m5"),
        5005,
        100000000,
    );

    // ========================================================
    // Settlement 6 — member6 : 40 + 40 = 80
    // ========================================================

    completeMemberSettlement(
        contract,
        m6,
        testing.treasury("final-wallet-m6"),
        5006,
        80000000,
    );

    // ========================================================
    // Settlement 7 — member7 : 40 + 20 = 60
    // ========================================================

    completeMemberSettlement(
        contract,
        m7,
        testing.treasury("final-wallet-m7"),
        5007,
        60000000,
    );

    // ========================================================
    // Settlement 8 — member8 : 40
    // ========================================================

    completeMemberSettlement(
        contract,
        m8,
        testing.treasury("final-wallet-m8"),
        5008,
        40000000,
    );

    // ========================================================
    // Settlement 9 — member9 : 40
    // ========================================================

    completeMemberSettlement(
        contract,
        m9,
        testing.treasury("final-wallet-m9"),
        5009,
        40000000,
    );

    // ========================================================
    // Settlement 10 — member10 : 40
    // ========================================================

    completeMemberSettlement(
        contract,
        m10,
        testing.treasury("final-wallet-m10"),
        5010,
        40000000,
    );

    // ========================================================
    // FINAL INVARIANTS
    // ========================================================

    // Le cercle reste terminé.
    expect(contract.state()).toEqual(5);
    expect(contract.currentRound()).toEqual(10);

    // Aucun settlement membre encore ouvert.
    expect(
        contract.settlementPending()
    ).toBeFalse();

    // Les 10 membres n'ont plus aucun actif bloqué.
    expect(contract.memberBond(alice.address)).toEqual(0);
    expect(contract.memberBond(bob.address)).toEqual(0);
    expect(contract.memberBond(m3.address)).toEqual(0);
    expect(contract.memberBond(m4.address)).toEqual(0);
    expect(contract.memberBond(m5.address)).toEqual(0);
    expect(contract.memberBond(m6.address)).toEqual(0);
    expect(contract.memberBond(m7.address)).toEqual(0);
    expect(contract.memberBond(m8.address)).toEqual(0);
    expect(contract.memberBond(m9.address)).toEqual(0);
    expect(contract.memberBond(m10.address)).toEqual(0);

    expect(contract.memberEscrow(alice.address)).toEqual(0);
    expect(contract.memberEscrow(bob.address)).toEqual(0);
    expect(contract.memberEscrow(m3.address)).toEqual(0);
    expect(contract.memberEscrow(m4.address)).toEqual(0);
    expect(contract.memberEscrow(m5.address)).toEqual(0);
    expect(contract.memberEscrow(m6.address)).toEqual(0);
    expect(contract.memberEscrow(m7.address)).toEqual(0);
    expect(contract.memberEscrow(m8.address)).toEqual(0);
    expect(contract.memberEscrow(m9.address)).toEqual(0);
    expect(contract.memberEscrow(m10.address)).toEqual(0);

    // Les frais protocole ne doivent surtout pas avoir été
    // consommés par les settlements membres.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);
}



get fun `test protocol treasury is stored separately`() {
    val (
        contract,
        controller,
        _,
        _,
        _,
        _,
        _
    ) = setupTest();

    val treasury =
        testing.treasury("protocol-treasury");

    expect(
        contract.protocolTreasuryAddress()
    ).toEqual(treasury.address);

    // Le rôle opérationnel et la trésorerie
    // sont volontairement séparés.
    expect(
        contract.protocolTreasuryAddress()
        != controller.address
    ).toBeTrue();
}



// ============================================================
// PROTOCOL FEES — BEGIN WITHDRAWAL
// ============================================================

get fun `test protocol treasury can begin fee wallet resolution`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // --------------------------------------------------------
    // La trésorerie ouvre le retrait.
    // --------------------------------------------------------

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6001),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val lookupTx =
        begin.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(lookupTx).toBeNotNull();

    val lookupBody =
        lookupTx!.loadBody<RequestWalletAddress>();

    expect(
        lookupBody.queryId
    ).toEqual(6001);

    expect(
        lookupBody.ownerAddress
    ).toEqual(protocolTreasury.address);

    expect(
        lookupBody.includeOwnerAddress
    ).toBeTrue();

    // --------------------------------------------------------
    // Etat figé à 50 USDT.
    // --------------------------------------------------------

    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeFalse();

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);

    // Très important :
    // les frais ne sont pas encore décrémentés.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // --------------------------------------------------------
    // Pendant ce retrait, Alice ne peut pas ouvrir
    // un settlement membre concurrent.
    // --------------------------------------------------------

    val conflictingSettlement = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(6002),
        { value: grams("0.1") }
    );

    expect(conflictingSettlement).toHaveFailedTx({
        from: alice.address,
        to: contract.address,
        exitCode: TontineErrors.ProtocolFeeOperationConflict,
    });

    // Le retrait des frais reste intact.
    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);
}



// ============================================================
// PROTOCOL FEES — WALLET RESOLUTION
// ============================================================

get fun `test authoritative master resolves protocol treasury jetton wallet`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    val treasuryJettonWallet =
        testing.treasury(
            "protocol-treasury-jetton-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6003),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeFalse();

    val responseBody = ResponseWalletAddress {
        queryId: 6003,
        jettonWalletAddress:
            treasuryJettonWallet.address,
        ownerAddress: protocolTreasury.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeTrue();

    expect(
        contract.protocolFeeTreasuryJettonWallet()
    ).toEqual(treasuryJettonWallet.address);

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);

    // Toujours aucun débit comptable.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);
}



get fun `test fake master cannot resolve protocol treasury jetton wallet`() {
    val (
        contract,
        controller,
        alice,
        bob,
        outsider,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    val fakeWallet =
        testing.treasury(
            "fake-protocol-treasury-wallet"
        );

    val realWallet =
        testing.treasury(
            "real-protocol-treasury-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6004),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // Faux Master.
    // --------------------------------------------------------

    val forgedBody = ResponseWalletAddress {
        queryId: 6004,
        jettonWalletAddress:
            fakeWallet.address,
        ownerAddress: protocolTreasury.address.toCell(),
    }.toCell();

    val forged = contract.sendAny(
        outsider.address,
        forgedBody,
        { value: grams("0.05") }
    );

    expect(forged).toHaveFailedTx({
        from: outsider.address,
        to: contract.address,
        exitCode: TontineErrors.UnauthorizedJettonWallet,
    });

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeFalse();

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // --------------------------------------------------------
    // Le vrai Master peut toujours répondre ensuite.
    // --------------------------------------------------------

    val realBody = ResponseWalletAddress {
        queryId: 6004,
        jettonWalletAddress:
            realWallet.address,
        ownerAddress: protocolTreasury.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        realBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeTrue();

    expect(
        contract.protocolFeeTreasuryJettonWallet()
    ).toEqual(realWallet.address);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);
}



// ============================================================
// PROTOCOL FEES — DISPATCH
// ============================================================

get fun `test protocol fee withdrawal dispatch sends fifty usdt`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    val treasuryJettonWallet =
        testing.treasury(
            "fee-dispatch-treasury-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6005),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 6005,
        jettonWalletAddress:
            treasuryJettonWallet.address,
        ownerAddress: protocolTreasury.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    val dispatched = contract.sendAny(
        protocolTreasury.address,
        makeDispatchProtocolFeeWithdrawalMessage(6005),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val transferTx =
        dispatched.findTransaction<AskToTransfer>({
            from: contract.address,
            to: usdtWallet.address,
        });

    expect(transferTx).toBeNotNull();

    val transferBody =
        transferTx!.loadBody<AskToTransfer>();

    expect(
        transferBody.queryId
    ).toEqual(6005);

    expect(
        transferBody.jettonAmount
    ).toEqual(50000000);

    expect(
        transferBody.transferRecipient
    ).toEqual(protocolTreasury.address);

    expect(
        transferBody.sendExcessesTo
    ).toEqual(contract.address);

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeTrue();

    // Aucun débit comptable avant excesses.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);

    expect(
        contract.protocolFeeWithdrawalDispatchedAt() > 0
    ).toBeTrue();

    // --------------------------------------------------------
    // Monitoring temporel uniquement :
    // aucun retry automatique n'est déclenché.
    // --------------------------------------------------------

    expect(
        contract.protocolFeeWithdrawalDispatchStale()
    ).toBeFalse();

    val dispatchedAt =
        contract.protocolFeeWithdrawalDispatchedAt();

    testing.setNow(
        (dispatchedAt + 3599) as uint32
    );

    expect(
        contract.protocolFeeWithdrawalDispatchStale()
    ).toBeFalse();

    testing.setNow(
        (dispatchedAt + 3600) as uint32
    );

    expect(
        contract.protocolFeeWithdrawalDispatchStale()
    ).toBeTrue();

    // Le flag stale est purement informatif.
    // L'état financier reste dispatched.
    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeTrue();

}



get fun `test bounced protocol fee transfer becomes dispatchable again`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    val treasuryJettonWallet =
        testing.treasury(
            "fee-bounce-treasury-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6006),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 6006,
        jettonWalletAddress:
            treasuryJettonWallet.address,
        ownerAddress: protocolTreasury.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    val dispatched = contract.sendAny(
        protocolTreasury.address,
        makeDispatchProtocolFeeWithdrawalMessage(6006),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeTrue();

    val transferTx =
        dispatched.findTransaction<AskToTransfer>({
            from: contract.address,
            to: usdtWallet.address,
        });

    expect(transferTx).toBeNotNull();

    val transferBody =
        transferTx!.loadBody<AskToTransfer>();

    val bouncedBody = beginCell()
        .storeUint(0xffffffff, 32)
        .storeSlice(
            transferBody.toCell().beginParse()
        )
        .endCell();

    val bouncedMessage = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: bouncedBody,
    }).bounced();

    testing.processSingleTraceStep(
        usdtWallet.address,
        bouncedMessage,
    );

    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeFalse();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeTrue();

    // Toujours 50 USDT comptabilisés.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);

    // --------------------------------------------------------
    // La trésorerie peut redispatcher.
    // --------------------------------------------------------

    val retry = contract.sendAny(
        protocolTreasury.address,
        makeDispatchProtocolFeeWithdrawalMessage(6006),
        { value: grams("0.15") }
    );

    expect(retry).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeTrue();

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);
}



// ============================================================
// PROTOCOL FEES — LOOKUP BOUNCE + RETRY
// ============================================================

get fun `test bounced protocol fee wallet lookup can be retried`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6007),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val lookupTx =
        begin.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(lookupTx).toBeNotNull();

    val lookupBody =
        lookupTx!.loadBody<RequestWalletAddress>();

    // --------------------------------------------------------
    // Le lookup bounce.
    // --------------------------------------------------------

    val bouncedBody = beginCell()
        .storeUint(0xffffffff, 32)
        .storeSlice(
            lookupBody.toCell().beginParse()
        )
        .endCell();

    val bouncedMessage = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: bouncedBody,
    }).bounced();

    testing.processSingleTraceStep(
        usdtMaster.address,
        bouncedMessage,
    );

    // Le retrait reste ouvert, mais le lookup est libéré.
    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeFalse();

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // --------------------------------------------------------
    // La trésorerie peut relancer la résolution.
    // --------------------------------------------------------

    val retry = contract.sendAny(
        protocolTreasury.address,
        makeRetryProtocolFeeWalletMessage(6007),
        { value: grams("0.1") }
    );

    expect(retry).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val retryLookupTx =
        retry.findTransaction<RequestWalletAddress>({
            from: contract.address,
            to: usdtMaster.address,
        });

    expect(retryLookupTx).toBeNotNull();

    val retryLookupBody =
        retryLookupTx!.loadBody<RequestWalletAddress>();

    expect(
        retryLookupBody.queryId
    ).toEqual(6007);

    expect(
        retryLookupBody.ownerAddress
    ).toEqual(protocolTreasury.address);

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeFalse();

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);
}



// ============================================================
// PROTOCOL FEES — AUTHENTICATED EXCESSES
// ============================================================

get fun `test authenticated protocol fee excesses finalizes withdrawal`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    val treasuryJettonWallet =
        testing.treasury(
            "final-protocol-treasury-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    // --------------------------------------------------------
    // 1. Begin withdrawal
    // --------------------------------------------------------

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6008),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // 2. Master officiel résout le wallet Jetton
    // --------------------------------------------------------

    val responseBody = ResponseWalletAddress {
        queryId: 6008,
        jettonWalletAddress:
            treasuryJettonWallet.address,
        ownerAddress: protocolTreasury.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // 3. Dispatch des 50 USDT
    // --------------------------------------------------------

    val dispatched = contract.sendAny(
        protocolTreasury.address,
        makeDispatchProtocolFeeWithdrawalMessage(6008),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeTrue();

    // Toujours comptabilisés avant confirmation.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // --------------------------------------------------------
    // 4. Excesses du wallet Jetton authentifié
    // --------------------------------------------------------

    val excessesBody = ReturnExcessesBack {
        queryId: 6008,
    }.toCell();

    val confirmed = contract.sendAny(
        treasuryJettonWallet.address,
        excessesBody,
        { value: grams("0.01") }
    );

    expect(confirmed).toHaveSuccessfulTx({
        from: treasuryJettonWallet.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // 5. Retrait définitivement finalisé
    // --------------------------------------------------------

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(0);

    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeFalse();

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeFalse();

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeFalse();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeFalse();

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(0);

    // --------------------------------------------------------
    // Aucun second retrait possible.
    // --------------------------------------------------------

    val duplicate = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6009),
        { value: grams("0.1") }
    );

    expect(duplicate).toHaveFailedTx({
        from: protocolTreasury.address,
        to: contract.address,
        exitCode: TontineErrors.ProtocolFeeNothingToWithdraw,
    });
}



get fun `test forged protocol fee excesses cannot finalize withdrawal`() {
    val (
        contract,
        controller,
        alice,
        bob,
        outsider,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    val treasuryJettonWallet =
        testing.treasury(
            "secure-final-protocol-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6010),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val responseBody = ResponseWalletAddress {
        queryId: 6010,
        jettonWalletAddress:
            treasuryJettonWallet.address,
        ownerAddress: protocolTreasury.address.toCell(),
    }.toCell();

    val resolved = contract.sendAny(
        usdtMaster.address,
        responseBody,
        { value: grams("0.05") }
    );

    expect(resolved).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    val dispatched = contract.sendAny(
        protocolTreasury.address,
        makeDispatchProtocolFeeWithdrawalMessage(6010),
        { value: grams("0.15") }
    );

    expect(dispatched).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    // --------------------------------------------------------
    // A. Faux wallet avec le bon queryId.
    // --------------------------------------------------------

    val forgedBody = ReturnExcessesBack {
        queryId: 6010,
    }.toCell();

    val forged = contract.sendAny(
        outsider.address,
        forgedBody,
        { value: grams("0.01") }
    );

    expect(forged).toHaveFailedTx({
        from: outsider.address,
        to: contract.address,
        exitCode: TontineErrors.UnauthorizedJettonWallet,
    });

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeTrue();

    // --------------------------------------------------------
    // B. Bon wallet, mauvais queryId.
    // --------------------------------------------------------

    val wrongQueryBody = ReturnExcessesBack {
        queryId: 999999,
    }.toCell();

    val wrongQuery = contract.sendAny(
        treasuryJettonWallet.address,
        wrongQueryBody,
        { value: grams("0.01") }
    );

    expect(wrongQuery).toHaveFailedTx({
        from: treasuryJettonWallet.address,
        to: contract.address,
        exitCode: TontineErrors.ProtocolFeeQueryMismatch,
    });

    // Aucun retrait frauduleux.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);

    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWithdrawalDispatched()
    ).toBeTrue();
}



// ============================================================
// PROTOCOL FEES — MEMBER FUNDS HAVE PRIORITY
// ============================================================

get fun `test protocol fees remain locked until every member is settled`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    // Les 10 rounds sont terminés...
    expect(
        contract.state()
    ).toEqual(5);

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // ...mais aucun remboursement final membre
    // n'a encore été confirmé.
    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(0);

    // La trésorerie ne peut donc pas toucher aux fees.
    val blocked = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6020),
        { value: grams("0.1") }
    );

    expect(blocked).toHaveFailedTx({
        from: protocolTreasury.address,
        to: contract.address,
        exitCode: TontineErrors.ProtocolFeeMembersNotSettled,
    });

    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeFalse();

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // --------------------------------------------------------
    // Finaliser les 10 obligations membres.
    // --------------------------------------------------------

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    // Les frais sont toujours intacts.
    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    // La condition de priorité des membres est désormais levée.
    val allowed = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6021),
        { value: grams("0.1") }
    );

    expect(allowed).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWithdrawalPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWithdrawalAmount()
    ).toEqual(50000000);
}



// ============================================================
// WALLET DISCOVERY — OWNER AUTHENTICATION
// ============================================================

get fun `test authoritative master cannot resolve payout wallet for wrong owner`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val candidateWallet =
        testing.treasury(
            "wrong-owner-payout-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    fundFullRoundOne(
        contract,
        usdtWallet,
        alice,
        bob,
    );

    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(910),
        { value: grams("0.1") }
    );

    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    val lookup = contract.sendAny(
        controller.address,
        makeResolvePayoutWalletMessage(910),
        { value: grams("0.1") }
    );

    expect(lookup).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    // Le vrai Master répond avec le bon queryId
    // mais prétend que le wallet appartient à Bob
    // alors que le bénéficiaire du round 1 est Alice.
    val wrongOwnerBody = ResponseWalletAddress {
        queryId: 910,
        jettonWalletAddress:
            candidateWallet.address,
        ownerAddress:
            bob.address.toCell(),
    }.toCell();

    val rejected = contract.sendAny(
        usdtMaster.address,
        wrongOwnerBody,
        { value: grams("0.05") }
    );

    expect(rejected).toHaveFailedTx({
        from: usdtMaster.address,
        to: contract.address,
        exitCode: TontineErrors.JettonWalletOwnerMismatch,
    });

    expect(
        contract.payoutBeneficiaryWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeFalse();

    // Le vrai owner peut toujours être accepté ensuite.
    val correctBody = ResponseWalletAddress {
        queryId: 910,
        jettonWalletAddress:
            candidateWallet.address,
        ownerAddress:
            alice.address.toCell(),
    }.toCell();

    val accepted = contract.sendAny(
        usdtMaster.address,
        correctBody,
        { value: grams("0.05") }
    );

    expect(accepted).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.payoutBeneficiaryWalletResolved()
    ).toBeTrue();
}



get fun `test authoritative master cannot resolve settlement wallet for wrong owner`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val usdtMaster =
        testing.treasury("usdt-master");

    val candidateWallet =
        testing.treasury(
            "wrong-owner-settlement-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    val claim = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4011),
        { value: grams("0.1") }
    );

    expect(claim).toHaveSuccessfulTx({
        from: alice.address,
        to: contract.address,
    });

    val wrongOwnerBody = ResponseWalletAddress {
        queryId: 4011,
        jettonWalletAddress:
            candidateWallet.address,
        ownerAddress:
            bob.address.toCell(),
    }.toCell();

    val rejected = contract.sendAny(
        usdtMaster.address,
        wrongOwnerBody,
        { value: grams("0.05") }
    );

    expect(rejected).toHaveFailedTx({
        from: usdtMaster.address,
        to: contract.address,
        exitCode: TontineErrors.JettonWalletOwnerMismatch,
    });

    expect(
        contract.settlementWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.settlementWalletResolved()
    ).toBeFalse();

    val correctBody = ResponseWalletAddress {
        queryId: 4011,
        jettonWalletAddress:
            candidateWallet.address,
        ownerAddress:
            alice.address.toCell(),
    }.toCell();

    val accepted = contract.sendAny(
        usdtMaster.address,
        correctBody,
        { value: grams("0.05") }
    );

    expect(accepted).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.settlementWalletResolved()
    ).toBeTrue();
}



get fun `test authoritative master cannot resolve treasury wallet for wrong owner`() {
    val (
        contract,
        controller,
        alice,
        bob,
        _,
        usdtWallet,
        _
    ) = setupTest();

    val protocolTreasury =
        testing.treasury("protocol-treasury");

    val usdtMaster =
        testing.treasury("usdt-master");

    val candidateWallet =
        testing.treasury(
            "wrong-owner-treasury-wallet"
        );

    prepareActiveCircle(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeCircleForSettlement(
        contract,
        controller,
        alice,
        bob,
        usdtWallet,
    );

    completeAllMemberSettlements(
        contract,
        alice,
        bob,
    );

    expect(
        contract.memberSettlementsCompleted()
    ).toEqual(10);

    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6011),
        { value: grams("0.1") }
    );

    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });

    val wrongOwnerBody = ResponseWalletAddress {
        queryId: 6011,
        jettonWalletAddress:
            candidateWallet.address,
        ownerAddress:
            alice.address.toCell(),
    }.toCell();

    val rejected = contract.sendAny(
        usdtMaster.address,
        wrongOwnerBody,
        { value: grams("0.05") }
    );

    expect(rejected).toHaveFailedTx({
        from: usdtMaster.address,
        to: contract.address,
        exitCode: TontineErrors.JettonWalletOwnerMismatch,
    });

    expect(
        contract.protocolFeeWalletLookupPending()
    ).toBeTrue();

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeFalse();

    expect(
        contract.protocolFeesAccrued()
    ).toEqual(50000000);

    val correctBody = ResponseWalletAddress {
        queryId: 6011,
        jettonWalletAddress:
            candidateWallet.address,
        ownerAddress:
            protocolTreasury.address.toCell(),
    }.toCell();

    val accepted = contract.sendAny(
        usdtMaster.address,
        correctBody,
        { value: grams("0.05") }
    );

    expect(accepted).toHaveSuccessfulTx({
        from: usdtMaster.address,
        to: contract.address,
    });

    expect(
        contract.protocolFeeWalletResolved()
    ).toBeTrue();
}


// ============================================================
// SECURITY AUDIT TESTS
// ============================================================

fun makeTruncatedBouncedAskToTransfer(
    queryId: uint64,
    jettonAmount: coins,
): cell {
    return beginCell()
        .storeUint(0xffffffff, 32)
        .storeUint(0x0f8a7ea5, 32)
        .storeUint(queryId, 64)
        .storeCoins(jettonAmount)
        .endCell();
}

fun makeTruncatedBouncedRequestWalletAddress(
    queryId: uint64,
): cell {
    return beginCell()
        .storeUint(0xffffffff, 32)
        .storeUint(0x2c76b973, 32)
        .storeUint(queryId, 64)
        .endCell();
}

fun advanceToCompletedCircle(
    contract: TontineCircle,
    controller: Treasury,
    alice: Treasury,
    bob: Treasury,
    usdtWallet: Treasury,
) {
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);
    completeCircleForSettlement(contract, controller, alice, bob, usdtWallet);
}

get fun `test prepare payout rejects non monotonic queryId`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);
    fundFullRoundOne(contract, usdtWallet, alice, bob);

    // Initial lastOperationQueryId is 0
    expect(contract.lastOperationQueryId()).toEqual(0);

    // QueryId 0 is rejected because 0 is not > 0
    val zeroQuery = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(0),
        { value: grams("0.1") }
    );
    expect(zeroQuery).toHaveFailedTx({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.ReplayedQueryId,
    });

    // Valid queryId 1000 succeeds
    val prepared = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(1000),
        { value: grams("0.1") }
    );
    expect(prepared).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });
    expect(contract.lastOperationQueryId()).toEqual(1000);
}

get fun `test settlement rejects non monotonic queryId and replay across operations`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    advanceToCompletedCircle(contract, controller, alice, bob, usdtWallet);

    // Payouts reached queryId 3010
    expect(contract.lastOperationQueryId()).toEqual(3010);

    // Alice attempts to use an old queryId (e.g. 3005 from round 5 payout)
    val replayOldPayoutQuery = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(3005),
        { value: grams("0.1") }
    );
    expect(replayOldPayoutQuery).toHaveFailedTx({
        from: alice.address,
        to: contract.address,
        exitCode: TontineErrors.ReplayedQueryId,
    });

    // Alice attempts to use queryId 3010 (same as last operation)
    val replaySameQuery = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(3010),
        { value: grams("0.1") }
    );
    expect(replaySameQuery).toHaveFailedTx({
        from: alice.address,
        to: contract.address,
        exitCode: TontineErrors.ReplayedQueryId,
    });

    // Alice uses strictly monotonic queryId 4001 -> succeeds
    completeMemberSettlement(
        contract,
        alice,
        testing.treasury("settle-wallet-alice-audit"),
        4001,
        180000000,
    );
    expect(contract.lastOperationQueryId()).toEqual(4001);

    // Bob attempts to replay Alice's settlement queryId 4001 -> rejected!
    val replayAliceQuery = contract.sendAny(
        bob.address,
        makeBeginSettlementMessage(4001),
        { value: grams("0.1") }
    );
    expect(replayAliceQuery).toHaveFailedTx({
        from: bob.address,
        to: contract.address,
        exitCode: TontineErrors.ReplayedQueryId,
    });

    // Bob attempts to use lower queryId 3500 -> rejected!
    val lowerQuery = contract.sendAny(
        bob.address,
        makeBeginSettlementMessage(3500),
        { value: grams("0.1") }
    );
    expect(lowerQuery).toHaveFailedTx({
        from: bob.address,
        to: contract.address,
        exitCode: TontineErrors.ReplayedQueryId,
    });

    // Bob uses strictly monotonic queryId 4002 -> succeeds
    completeMemberSettlement(
        contract,
        bob,
        testing.treasury("settle-wallet-bob-audit"),
        4002,
        160000000,
    );
    expect(contract.lastOperationQueryId()).toEqual(4002);
}

get fun `test protocol fee withdrawal rejects non monotonic queryId`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    advanceToCompletedCircle(contract, controller, alice, bob, usdtWallet);
    completeAllMemberSettlements(contract, alice, bob);

    val protocolTreasury = testing.treasury("protocol-treasury");
    expect(contract.lastOperationQueryId()).toEqual(5010);

    // Treasury attempts to replay queryId 5005 from member settlement
    val replaySettlementQuery = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(5005),
        { value: grams("0.1") }
    );
    expect(replaySettlementQuery).toHaveFailedTx({
        from: protocolTreasury.address,
        to: contract.address,
        exitCode: TontineErrors.ReplayedQueryId,
    });

    // Treasury attempts to replay queryId 3010 from payout
    val replayPayoutQuery = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(3010),
        { value: grams("0.1") }
    );
    expect(replayPayoutQuery).toHaveFailedTx({
        from: protocolTreasury.address,
        to: contract.address,
        exitCode: TontineErrors.ReplayedQueryId,
    });

    // Treasury uses monotonic queryId 6001 -> succeeds
    val begin = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6001),
        { value: grams("0.1") }
    );
    expect(begin).toHaveSuccessfulTx({
        from: protocolTreasury.address,
        to: contract.address,
    });
    expect(contract.lastOperationQueryId()).toEqual(6001);
}

get fun `test delayed excess cannot finalize subsequent round payout`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);

    val aliceWallet = testing.treasury("alice-payout-wallet");
    val bobWallet = testing.treasury("bob-payout-wallet");

    // Round 1 completed with queryId 1001
    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(contract, controller, aliceWallet, 1001);

    // Round 2 setup
    fundFullRoundOne(contract, usdtWallet, alice, bob);
    contract.sendAny(controller.address, makePreparePayoutMessage(1002), { value: grams("0.1") });
    contract.sendAny(controller.address, makeResolvePayoutWalletMessage(1002), { value: grams("0.1") });

    val master = testing.treasury("usdt-master");
    contract.sendAny(
        master.address,
        ResponseWalletAddress {
            queryId: 1002,
            jettonWalletAddress: bobWallet.address,
            ownerAddress: bob.address.toCell(),
        }.toCell(),
        { value: grams("0.05") }
    );

    contract.sendAny(controller.address, makeDispatchPayoutMessage(1002), { value: grams("0.15") });
    expect(contract.payoutDispatched()).toBeTrue();

    // Adversarial / delayed excess from Round 1 (queryId 1001) sent to Round 2
    val delayedExcessAlice = contract.sendAny(
        aliceWallet.address,
        ReturnExcessesBack { queryId: 1001 }.toCell(),
        { value: grams("0.01") }
    );
    // Rejected because sender is not Round 2's resolved beneficiary wallet (bobWallet)
    expect(delayedExcessAlice).toHaveFailedTx({
        from: aliceWallet.address,
        to: contract.address,
        exitCode: TontineErrors.UnauthorizedJettonWallet,
    });

    // Even if sent from bobWallet with queryId 1001:
    val delayedExcessBob = contract.sendAny(
        bobWallet.address,
        ReturnExcessesBack { queryId: 1001 }.toCell(),
        { value: grams("0.01") }
    );
    // Rejected because queryId doesn't match active pending payout queryId (1002)
    expect(delayedExcessBob).toHaveFailedTx({
        from: bobWallet.address,
        to: contract.address,
        exitCode: TontineErrors.PayoutQueryMismatch,
    });

    // Round 2 remains pending and uncorrupted
    expect(contract.payoutPending()).toBeTrue();
    expect(contract.payoutDispatched()).toBeTrue();
}

get fun `test delayed wallet response cannot resolve subsequent round lookup`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);

    val aliceWallet = testing.treasury("alice-wallet-1001");
    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(contract, controller, aliceWallet, 1001);

    // Round 2
    fundFullRoundOne(contract, usdtWallet, alice, bob);
    contract.sendAny(controller.address, makePreparePayoutMessage(1002), { value: grams("0.1") });
    contract.sendAny(controller.address, makeResolvePayoutWalletMessage(1002), { value: grams("0.1") });

    val master = testing.treasury("usdt-master");

    // Delayed response with queryId 1001
    val delayedResponse = contract.sendAny(
        master.address,
        ResponseWalletAddress {
            queryId: 1001,
            jettonWalletAddress: aliceWallet.address,
            ownerAddress: bob.address.toCell(),
        }.toCell(),
        { value: grams("0.05") }
    );
    expect(delayedResponse).toHaveFailedTx({
        from: master.address,
        to: contract.address,
        exitCode: TontineErrors.PayoutQueryMismatch,
    });

    expect(contract.payoutBeneficiaryWalletResolved()).toBeFalse();
    expect(contract.payoutBeneficiaryWalletLookupPending()).toBeTrue();
}

get fun `test delayed bounce from previous round does not reset dispatched on active payout`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);

    val aliceWallet = testing.treasury("alice-payout-w1");
    val bobWallet = testing.treasury("bob-payout-w2");

    // Round 1 completed
    fundFullRoundOne(contract, usdtWallet, alice, bob);
    completeCurrentRoundPayout(contract, controller, aliceWallet, 1001);

    // Round 2 dispatched
    fundFullRoundOne(contract, usdtWallet, alice, bob);
    contract.sendAny(controller.address, makePreparePayoutMessage(1002), { value: grams("0.1") });
    contract.sendAny(controller.address, makeResolvePayoutWalletMessage(1002), { value: grams("0.1") });
    val master = testing.treasury("usdt-master");
    contract.sendAny(
        master.address,
        ResponseWalletAddress {
            queryId: 1002,
            jettonWalletAddress: bobWallet.address,
            ownerAddress: bob.address.toCell(),
        }.toCell(),
        { value: grams("0.05") }
    );
    contract.sendAny(controller.address, makeDispatchPayoutMessage(1002), { value: grams("0.15") });
    expect(contract.payoutDispatched()).toBeTrue();

    // Delayed bounce from round 1 with queryId 1001 arrives
    val oldBouncedMsg = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: makeTruncatedBouncedAskToTransfer(1001, 55000000),
    }).bounced();

    testing.processSingleTraceStep(usdtWallet.address, oldBouncedMsg);

    // Round 2 payout remains dispatched (not reset!)
    expect(contract.payoutDispatched()).toBeTrue();
}

get fun `test real 256 bit truncated bounce resets payout dispatch safely`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);
    fundFullRoundOne(contract, usdtWallet, alice, bob);

    contract.sendAny(controller.address, makePreparePayoutMessage(1001), { value: grams("0.1") });
    contract.sendAny(controller.address, makeResolvePayoutWalletMessage(1001), { value: grams("0.1") });

    val master = testing.treasury("usdt-master");
    val aliceWallet = testing.treasury("alice-w-trunc");
    contract.sendAny(
        master.address,
        ResponseWalletAddress {
            queryId: 1001,
            jettonWalletAddress: aliceWallet.address,
            ownerAddress: alice.address.toCell(),
        }.toCell(),
        { value: grams("0.05") }
    );

    contract.sendAny(controller.address, makeDispatchPayoutMessage(1001), { value: grams("0.15") });
    expect(contract.payoutDispatched()).toBeTrue();
    expect(contract.payoutDispatchedAt()).toBeGreater(0);

    // Send authentic 256-bit TVM truncated bounce (only prefix, op, queryId, coins)
    val truncatedBounce = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: makeTruncatedBouncedAskToTransfer(1001, 55000000),
    }).bounced();

    testing.processSingleTraceStep(usdtWallet.address, truncatedBounce);

    // Dispatched is reset to false and dispatchedAt reset to 0 without TVM underflow
    expect(contract.payoutDispatched()).toBeFalse();
    expect(contract.payoutDispatchedAt()).toEqual(0);
    expect(contract.payoutPending()).toBeTrue();
}

get fun `test real 256 bit truncated bounce resets settlement dispatch safely`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    advanceToCompletedCircle(contract, controller, alice, bob, usdtWallet);

    val master = testing.treasury("usdt-master");
    val aliceSettleWallet = testing.treasury("alice-settle-trunc");

    contract.sendAny(alice.address, makeBeginSettlementMessage(4001), { value: grams("0.1") });
    contract.sendAny(
        master.address,
        ResponseWalletAddress {
            queryId: 4001,
            jettonWalletAddress: aliceSettleWallet.address,
            ownerAddress: alice.address.toCell(),
        }.toCell(),
        { value: grams("0.05") }
    );

    contract.sendAny(alice.address, makeDispatchSettlementMessage(4001), { value: grams("0.15") });
    expect(contract.settlementDispatched()).toBeTrue();
    expect(contract.settlementDispatchedAt()).toBeGreater(0);

    // Send authentic 256-bit TVM truncated bounce for settlement (180 USDT)
    val truncatedBounce = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: makeTruncatedBouncedAskToTransfer(4001, 180000000),
    }).bounced();

    testing.processSingleTraceStep(usdtWallet.address, truncatedBounce);

    // Settlement dispatch reset to false and timestamp reset to 0
    expect(contract.settlementDispatched()).toBeFalse();
    expect(contract.settlementDispatchedAt()).toEqual(0);
    expect(contract.settlementPending()).toBeTrue();
}

get fun `test real 256 bit truncated bounce resets wallet lookup safely`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);
    fundFullRoundOne(contract, usdtWallet, alice, bob);

    contract.sendAny(controller.address, makePreparePayoutMessage(1001), { value: grams("0.1") });
    contract.sendAny(controller.address, makeResolvePayoutWalletMessage(1001), { value: grams("0.1") });
    expect(contract.payoutBeneficiaryWalletLookupPending()).toBeTrue();

    val master = testing.treasury("usdt-master");

    // Send authentic 256-bit TVM truncated bounce for RequestWalletAddress (only prefix, op, queryId)
    val truncatedLookupBounce = createMessage({
        bounce: false,
        value: grams("0.05"),
        dest: contract.address,
        body: makeTruncatedBouncedRequestWalletAddress(1001),
    }).bounced();

    testing.processSingleTraceStep(master.address, truncatedLookupBounce);

    // Lookup pending reset to false without cell underflow
    expect(contract.payoutBeneficiaryWalletLookupPending()).toBeFalse();
}

get fun `test malformed message with fewer than 32 bits is rejected cleanly`() {
    val (contract, controller, _, _, _, _, _) = setupTest();

    // 16 bits body
    val shortBody = beginCell().storeUint(0x1234, 16).endCell();

    val res = contract.sendAny(
        controller.address,
        shortBody,
        { value: grams("0.1") }
    );

    expect(res).toHaveFailedTx({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidMessage,
    });
}

get fun `test accounting invariants: 960 liabilities 50 fees 1010 total`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    advanceToCompletedCircle(contract, controller, alice, bob, usdtWallet);

    // Member 1 (Alice): 140 escrow + 40 bond = 180 USDT
    expect(contract.memberSettlementDue(alice.address)).toEqual(180000000);
    expect(contract.memberBond(alice.address)).toEqual(40000000);
    expect(contract.memberEscrow(alice.address)).toEqual(140000000);

    // Member 2 (Bob): 120 escrow + 40 bond = 160 USDT
    expect(contract.memberSettlementDue(bob.address)).toEqual(160000000);

    // Members 3 to 10
    val m3 = testing.treasury("member3");
    val m4 = testing.treasury("member4");
    val m5 = testing.treasury("member5");
    val m6 = testing.treasury("member6");
    val m7 = testing.treasury("member7");
    val m8 = testing.treasury("member8");
    val m9 = testing.treasury("member9");
    val m10 = testing.treasury("member10");

    expect(contract.memberSettlementDue(m3.address)).toEqual(140000000);
    expect(contract.memberSettlementDue(m4.address)).toEqual(120000000);
    expect(contract.memberSettlementDue(m5.address)).toEqual(100000000);
    expect(contract.memberSettlementDue(m6.address)).toEqual(80000000);
    expect(contract.memberSettlementDue(m7.address)).toEqual(60000000);
    expect(contract.memberSettlementDue(m8.address)).toEqual(40000000);
    expect(contract.memberSettlementDue(m9.address)).toEqual(40000000);
    expect(contract.memberSettlementDue(m10.address)).toEqual(40000000);

    // Total liabilities = 180 + 160 + 140 + 120 + 100 + 80 + 60 + 40 + 40 + 40 = 960 USDT
    val totalMemberLiabilities: uint64 =
        contract.memberSettlementDue(alice.address)
        + contract.memberSettlementDue(bob.address)
        + contract.memberSettlementDue(m3.address)
        + contract.memberSettlementDue(m4.address)
        + contract.memberSettlementDue(m5.address)
        + contract.memberSettlementDue(m6.address)
        + contract.memberSettlementDue(m7.address)
        + contract.memberSettlementDue(m8.address)
        + contract.memberSettlementDue(m9.address)
        + contract.memberSettlementDue(m10.address);

    expect(totalMemberLiabilities).toEqual(960000000);

    // Accrued fees across 10 rounds = 50 USDT
    expect(contract.protocolFeesAccrued()).toEqual(50000000);

    // Total required reserves = 1010 USDT
    val totalRequiredReserves: uint64 = totalMemberLiabilities + contract.protocolFeesAccrued();
    expect(totalRequiredReserves).toEqual(1010000000);

    // Complete all 10 member settlements
    completeAllMemberSettlements(contract, alice, bob);

    expect(contract.memberSettlementsCompleted()).toEqual(10);
    expect(contract.memberSettlementDue(alice.address)).toEqual(0);
    expect(contract.memberSettlementDue(bob.address)).toEqual(0);
    expect(contract.memberSettlementDue(m10.address)).toEqual(0);

    // Protocol fees remained intact at 50 USDT
    expect(contract.protocolFeesAccrued()).toEqual(50000000);
}

get fun `test cannot contribute or prepare payout in completed state`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    advanceToCompletedCircle(contract, controller, alice, bob, usdtWallet);

    expect(contract.state()).toEqual(5);

    // Contribution in COMPLETED state is rejected
    val notif = contract.sendAny(
        usdtWallet.address,
        makeJettonNotification(9999, 20000000, alice.address),
        { value: grams("0.1") }
    );
    expect(notif).toHaveFailedTx({
        from: usdtWallet.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidState,
    });

    // Prepare payout in COMPLETED state is rejected
    val prep = contract.sendAny(
        controller.address,
        makePreparePayoutMessage(9999),
        { value: grams("0.1") }
    );
    expect(prep).toHaveFailedTx({
        from: controller.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidState,
    });
}

get fun `test non member cannot begin settlement`() {
    val (contract, controller, alice, bob, outsider, usdtWallet, _) = setupTest();
    advanceToCompletedCircle(contract, controller, alice, bob, usdtWallet);

    val res = contract.sendAny(
        outsider.address,
        makeBeginSettlementMessage(4001),
        { value: grams("0.1") }
    );
    expect(res).toHaveFailedTx({
        from: outsider.address,
        to: contract.address,
        exitCode: TontineErrors.MemberNotFound,
    });
}

get fun `test member cannot begin settlement before completed state`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    prepareActiveCircle(contract, controller, alice, bob, usdtWallet);

    expect(contract.state()).toEqual(4);

    val res = contract.sendAny(
        alice.address,
        makeBeginSettlementMessage(4001),
        { value: grams("0.1") }
    );
    expect(res).toHaveFailedTx({
        from: alice.address,
        to: contract.address,
        exitCode: TontineErrors.InvalidState,
    });
}

get fun `test double protocol fee withdrawal is impossible`() {
    val (contract, controller, alice, bob, _, usdtWallet, _) = setupTest();
    advanceToCompletedCircle(contract, controller, alice, bob, usdtWallet);
    completeAllMemberSettlements(contract, alice, bob);

    val protocolTreasury = testing.treasury("protocol-treasury");
    val treasuryWallet = testing.treasury("treasury-audit-jetton-wallet");
    val master = testing.treasury("usdt-master");

    // First withdrawal
    contract.sendAny(protocolTreasury.address, makeBeginProtocolFeeWithdrawalMessage(6001), { value: grams("0.1") });
    contract.sendAny(
        master.address,
        ResponseWalletAddress {
            queryId: 6001,
            jettonWalletAddress: treasuryWallet.address,
            ownerAddress: protocolTreasury.address.toCell(),
        }.toCell(),
        { value: grams("0.05") }
    );
    contract.sendAny(protocolTreasury.address, makeDispatchProtocolFeeWithdrawalMessage(6001), { value: grams("0.15") });
    contract.sendAny(treasuryWallet.address, ReturnExcessesBack { queryId: 6001 }.toCell(), { value: grams("0.01") });

    expect(contract.protocolFeesAccrued()).toEqual(0);

    // Second withdrawal attempt
    val secondAttempt = contract.sendAny(
        protocolTreasury.address,
        makeBeginProtocolFeeWithdrawalMessage(6002),
        { value: grams("0.1") }
    );
    expect(secondAttempt).toHaveFailedTx({
        from: protocolTreasury.address,
        to: contract.address,
        exitCode: TontineErrors.ProtocolFeeNothingToWithdraw,
    });
}

