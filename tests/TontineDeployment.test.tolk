import "@stdlib/gas-payments"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@acton/types/message"

import "@wrappers/TontineCircle.gen"
import "../contracts/tontineStorage"
import "../contracts/tontineTypes"

get fun `test canonical storage builder creates exact zeroed and default initial fields`() {
    val controller = testing.treasury("deploy-test-ctrl");
    val usdtMaster = testing.treasury("deploy-test-master");
    val treasury = testing.treasury("deploy-test-treasury");

    val storage = buildInitialTontineStorage(
        42,
        controller.address,
        usdtMaster.address,
        treasury.address,
    );

    // Root storage fields
    expect(storage.circleId).toEqual(42);
    expect(storage.controller).toEqual(controller.address);
    expect(storage.usdtWallet).toBeNull();
    expect(storage.state).toEqual(1); // OPEN
    expect(storage.currentRound).toEqual(0);
    expect(storage.memberCount).toEqual(10);
    expect(storage.registeredCount).toEqual(0);
    expect(storage.fundedBondCount).toEqual(0);
    expect(storage.roundContributionCount).toEqual(0);
    expect(storage.roundCollected).toEqual(0);
    expect(storage.contributionAmount).toEqual(20000000);
    expect(storage.personalBond).toEqual(40000000);
    expect(storage.protocolFeeBps).toEqual(250);

    // Maps must be empty
    expect(storage.members.exists(controller.address)).toBeFalse();
    expect(storage.roundOwners.exists(1)).toBeFalse();

    // ProtocolState fields
    val protocolState = storage.protocolState.load();
    expect(protocolState.memberSettlementsCompleted).toEqual(0);
    expect(protocolState.lastOperationQueryId).toEqual(0);

    // JettonMasterConfig fields
    val config = protocolState.jettonMasterConfig.load();
    expect(config.usdtMaster).toEqual(usdtMaster.address);
    expect(config.protocolTreasury).toEqual(treasury.address);
    expect(config.circleWalletLookupPending).toBeFalse();
    expect(config.circleWalletResolved).toBeFalse();
    expect(config.circleWalletQueryId).toEqual(0);

    // SettlementState fields
    val settlement = protocolState.settlement.load();
    expect(settlement.settlementPending).toBeFalse();
    expect(settlement.walletLookupPending).toBeFalse();
    expect(settlement.settlementDispatched).toBeFalse();
    expect(settlement.settlementDispatchedAt).toEqual(0);
    expect(settlement.memberAddress).toBeNull();
    expect(settlement.memberJettonWallet).toBeNull();
    expect(settlement.amount).toEqual(0);
    expect(settlement.queryId).toEqual(0);

    // ProtocolFeeState fields
    val feeState = protocolState.feeState.load();
    expect(feeState.withdrawalPending).toBeFalse();
    expect(feeState.walletLookupPending).toBeFalse();
    expect(feeState.withdrawalDispatched).toBeFalse();
    expect(feeState.withdrawalDispatchedAt).toEqual(0);
    expect(feeState.treasuryJettonWallet).toBeNull();
    expect(feeState.amount).toEqual(0);
    expect(feeState.queryId).toEqual(0);

    // PayoutState fields
    val payout = storage.payout.load();
    expect(payout.payoutPending).toBeFalse();
    expect(payout.payoutDispatched).toBeFalse();
    expect(payout.payoutDispatchedAt).toEqual(0);
    expect(payout.beneficiaryWalletLookupPending).toBeFalse();
    expect(payout.beneficiaryJettonWallet).toBeNull();
    expect(payout.pendingPayoutRound).toEqual(0);
    expect(payout.pendingPayoutAmount).toEqual(0);
    expect(payout.pendingPayoutEscrow).toEqual(0);
    expect(payout.pendingPayoutFee).toEqual(0);
    expect(payout.pendingPayoutQueryId).toEqual(0);
    expect(payout.protocolFeesAccrued).toEqual(0);
}

get fun `test canonical deployment in emulator exposes exact verified getters`() {
    val controller = testing.treasury("deploy-emul-ctrl");
    val usdtMaster = testing.treasury("deploy-emul-master");
    val treasury = testing.treasury("deploy-emul-treasury");

    val storage = buildInitialTontineStorage(
        777,
        controller.address,
        usdtMaster.address,
        treasury.address,
    );

    val contract = TontineCircle.fromStorage(storage);
    val deployRes = contract.deploy(controller.address, { value: grams("1") });
    expect(deployRes).toHaveSuccessfulDeploy({
        to: contract.address
    });

    // Verification of all exposed initial getters
    expect(contract.circleId()).toEqual(777);
    expect(contract.state()).toEqual(1);
    expect(contract.currentRound()).toEqual(0);
    expect(contract.memberCount()).toEqual(10);
    expect(contract.registeredCount()).toEqual(0);
    expect(contract.fundedBondCount()).toEqual(0);
    expect(contract.roundContributionCount()).toEqual(0);
    expect(contract.roundCollected()).toEqual(0);
    expect(contract.contributionAmount()).toEqual(20000000);
    expect(contract.personalBond()).toEqual(40000000);
    expect(contract.protocolFeeBps()).toEqual(250);

    // Initial nonce & wallet resolution invariants
    expect(contract.lastOperationQueryId()).toEqual(0);
    expect(contract.circleJettonWalletResolved()).toBeFalse();
    expect(contract.circleJettonWalletLookupPending()).toBeFalse();

    // Inactive pending states
    expect(contract.payoutPending()).toBeFalse();
    expect(contract.payoutDispatched()).toBeFalse();
    expect(contract.pendingPayoutRound()).toEqual(0);
    expect(contract.pendingPayoutAmount()).toEqual(0);
    expect(contract.pendingPayoutEscrow()).toEqual(0);
    expect(contract.pendingPayoutFee()).toEqual(0);

    expect(contract.settlementPending()).toBeFalse();
    expect(contract.settlementDispatched()).toBeFalse();
    expect(contract.settlementWalletLookupPending()).toBeFalse();
    expect(contract.settlementAmount()).toEqual(0);

    expect(contract.protocolFeeWithdrawalPending()).toBeFalse();
    expect(contract.protocolFeeWithdrawalDispatched()).toBeFalse();
    expect(contract.protocolFeeWalletLookupPending()).toBeFalse();
    expect(contract.protocolFeeWithdrawalAmount()).toEqual(0);
    expect(contract.protocolFeesAccrued()).toEqual(0);

    // Addresses
    expect(contract.usdtMasterAddress()).toEqual(usdtMaster.address);
    expect(contract.protocolTreasuryAddress()).toEqual(treasury.address);
}

get fun `test canonical deployed contract seamlessly begins circle wallet resolution`() {
    val controller = testing.treasury("deploy-res-ctrl");
    val usdtMaster = testing.treasury("deploy-res-master");
    val treasury = testing.treasury("deploy-res-treasury");

    val storage = buildInitialTontineStorage(
        1000,
        controller.address,
        usdtMaster.address,
        treasury.address,
    );

    val contract = TontineCircle.fromStorage(storage);
    val deployRes = contract.deploy(controller.address, { value: grams("1") });
    expect(deployRes).toHaveSuccessfulDeploy({
        to: contract.address
    });

    // Controller triggers canonical TEP-89 circle wallet resolution
    val resolutionMsg = beginCell()
        .storeUint(0x52434A57, 32)
        .storeUint(10, 64)
        .endCell();

    val res = contract.sendAny(controller.address, resolutionMsg, { value: grams("0.2") });
    expect(res).toHaveSuccessfulTx({
        from: controller.address,
        to: contract.address,
    });

    expect(contract.circleJettonWalletLookupPending()).toBeTrue();
    expect(contract.circleJettonWalletResolved()).toBeFalse();
}
