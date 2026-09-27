import "tontineTypes"

/// Builds the canonical initial storage for a new TontineCircle deployment.
///
/// Parameters that vary per deployment:
/// - `circleId`: Unique circle identifier (uint64)
/// - `controller`: Circle orchestrator / admin address
/// - `usdtMaster`: Authoritative USDT Jetton Minter address
/// - `protocolTreasury`: Protocol treasury recipient address for fees
///
/// All other fields are fixed to their canonical initial values:
/// - `lastOperationQueryId`: 0 (guaranteed initial sequential nonce)
/// - `usdtWallet`: null (deliberately unresolved at deployment)
/// - `circleWalletResolved`: false (requires post-deploy TEP-89 lookup)
/// - `circleWalletLookupPending`: false
/// - `circleWalletQueryId`: 0
/// - `state`: 1 (OPEN)
/// - `currentRound`: 0
/// - `memberCount`: 10
/// - all counters: 0
/// - `contributionAmount`: 20_000_000 (20 USDT)
/// - `personalBond`: 40_000_000 (40 USDT)
/// - `protocolFeeBps`: 250 (2.5%)
/// - `members`: empty map
/// - `roundOwners`: empty map
/// - `payout`, `settlement`, `feeState`: cleanly reset to idle/empty
fun buildInitialTontineStorage(
    circleId: uint64,
    controller: address,
    usdtMaster: address,
    protocolTreasury: address,
): TontineStorage {
    val jettonMasterConfig = JettonMasterConfig {
        usdtMaster,
        protocolTreasury,
        circleWalletLookupPending: false,
        circleWalletResolved: false,
        circleWalletQueryId: 0,
    };

    val settlement = SettlementState {
        settlementPending: false,
        walletLookupPending: false,
        settlementDispatched: false,
        settlementDispatchedAt: 0,
        memberAddress: null,
        memberJettonWallet: null,
        amount: 0,
        queryId: 0,
    };

    val feeState = ProtocolFeeState {
        withdrawalPending: false,
        walletLookupPending: false,
        withdrawalDispatched: false,
        withdrawalDispatchedAt: 0,
        treasuryJettonWallet: null,
        amount: 0,
        queryId: 0,
    };

    val protocolState = ProtocolState {
        jettonMasterConfig: jettonMasterConfig.toCell(),
        settlement: settlement.toCell(),
        feeState: feeState.toCell(),
        memberSettlementsCompleted: 0,
        lastOperationQueryId: 0,
    };

    val payout = PayoutState {
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
    };

    return TontineStorage {
        circleId,
        controller,
        usdtWallet: null,

        protocolState: protocolState.toCell(),

        state: 1, // OPEN
        currentRound: 0,

        memberCount: 10,
        registeredCount: 0,
        fundedBondCount: 0,
        roundContributionCount: 0,
        roundCollected: 0,

        payout: payout.toCell(),

        contributionAmount: 20000000,
        personalBond: 40000000,
        protocolFeeBps: 250,

        members: [],
        roundOwners: [],
    };
}
