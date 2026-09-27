enum TontineErrors {
    NotController = 1000
    MemberNotFound = 1001
    MemberAlreadyExists = 1002
    RoundAlreadyAssigned = 1003
    InvalidAssignedRound = 1004
    CircleFull = 1005
    InvalidState = 1006
    CircleNotFullyRegistered = 1007
    BondsNotFullyFunded = 1008

    UnauthorizedJettonWallet = 1100
    InvalidBondAmount = 1101
    BondAlreadyFunded = 1102
    InvalidContributionAmount = 1103
    ContributionAlreadyPaid = 1104
    MemberBondNotFunded = 1105
    NoRemainingDebt = 1106
    JettonWalletOwnerMismatch = 1107

    RoundNotFullyFunded = 1200
    InvalidPayoutMath = 1201
    PayoutAlreadyPending = 1202
    BeneficiaryAlreadyPaid = 1203
    PayoutNotPending = 1204
    PayoutAlreadyDispatched = 1205
    PayoutQueryMismatch = 1206
    WalletLookupAlreadyPending = 1207
    WalletAlreadyResolved = 1208
    WalletNotResolved = 1209
    PayoutNotDispatched = 1210
    PayoutRoundMismatch = 1211

    SettlementAlreadyPending = 1300
    SettlementNotEligible = 1301
    SettlementNothingToClaim = 1302
    SettlementQueryMismatch = 1303
    SettlementWalletNotResolved = 1304
    SettlementNotPending = 1305
    SettlementMemberMismatch = 1306
    SettlementWalletLookupAlreadyPending = 1307
    SettlementWalletAlreadyResolved = 1308
    SettlementAlreadyDispatched = 1309
    SettlementNotDispatched = 1310
    SettlementAmountMismatch = 1311
    SettlementCountInvariant = 1312

    ProtocolFeeWithdrawalAlreadyPending = 1400
    ProtocolFeeWithdrawalNotPending = 1401
    ProtocolFeeNothingToWithdraw = 1402
    ProtocolFeeQueryMismatch = 1403
    ProtocolFeeWalletNotResolved = 1404
    ProtocolFeeOperationConflict = 1405
    UnauthorizedProtocolTreasury = 1406
    ProtocolFeeAlreadyDispatched = 1407
    ProtocolFeeNotDispatched = 1408
    ProtocolFeeWalletLookupAlreadyPending = 1409
    ProtocolFeeWalletAlreadyResolved = 1410
    ProtocolFeeAmountMismatch = 1411
    ProtocolFeeMembersNotSettled = 1412

    ReplayedQueryId = 1500
    QueryIdOverflow = 1501

    CircleWalletQueryMismatch = 1212
    CircleWalletAlreadyResolved = 1213
    CircleWalletNotResolved = 1214
    CircleWalletLookupAlreadyPending = 1215

    InvalidMessage = 0xFFFF
}

struct MemberPosition {
    memberId: uint16
    assignedRound: uint8
    status: uint8

    totalContributed: uint64
    remainingDebt: uint64

    bondLocked: uint64
    escrowLocked: uint64

    p2pGuaranteeActive: uint64
    protocolGuaranteeActive: uint64

    beneficiaryPaid: bool
    defaultDeclared: bool
    lastContributionRound: uint8
}

struct PayoutState {
    payoutPending: bool
    payoutDispatched: bool
    payoutDispatchedAt: uint64
    beneficiaryWalletLookupPending: bool
    beneficiaryJettonWallet: address?
    pendingPayoutRound: uint8
    pendingPayoutAmount: uint64
    pendingPayoutEscrow: uint64
    pendingPayoutFee: uint64
    pendingPayoutQueryId: uint64
    protocolFeesAccrued: uint64
}

struct SettlementState {
    settlementPending: bool
    walletLookupPending: bool
    settlementDispatched: bool
    settlementDispatchedAt: uint64

    memberAddress: address?
    memberJettonWallet: address?

    amount: uint64
    queryId: uint64
}


struct JettonMasterConfig {
    usdtMaster: address
    protocolTreasury: address
    circleWalletLookupPending: bool
    circleWalletResolved: bool
    circleWalletQueryId: uint64
}


struct ProtocolFeeState {
    withdrawalPending: bool
    walletLookupPending: bool
    withdrawalDispatched: bool
    withdrawalDispatchedAt: uint64

    treasuryJettonWallet: address?

    amount: uint64
    queryId: uint64
}


struct ProtocolState {
    jettonMasterConfig: Cell<JettonMasterConfig>
    settlement: Cell<SettlementState>
    feeState: Cell<ProtocolFeeState>
    memberSettlementsCompleted: uint8
    lastOperationQueryId: uint64
}

struct TontineStorage {
    circleId: uint64
    controller: address

    // Jetton Wallet USDT appartenant à ce contrat (résolu auprès du usdtMaster).
    usdtWallet: address?

    protocolState: Cell<ProtocolState>
    // 0 = DRAFT
    // 1 = OPEN
    // 2 = READY
    // 3 = LOCKED
    // 4 = ACTIVE
    // 5 = COMPLETED
    state: uint8

    currentRound: uint8

    memberCount: uint8
    registeredCount: uint8
    fundedBondCount: uint8
    roundContributionCount: uint8
    roundCollected: uint64

    payout: Cell<PayoutState>

    contributionAmount: uint64
    personalBond: uint64

    protocolFeeBps: uint16

    members: map<address, MemberPosition>
    roundOwners: map<uint8, address>
}

fun TontineStorage.load(): TontineStorage {
    return TontineStorage.fromCell(contract.getData());
}

fun TontineStorage.save(self) {
    contract.setData(self.toCell());
}


// ------------------------------------------------------------------
// Administration du cercle
// ------------------------------------------------------------------

struct (0x41444D42) AddMember {
    memberId: uint16
    wallet: address
    assignedRound: uint8
}

// 0x52434A57 = "RCJW" (Resolve Circle Jetton Wallet)
struct (0x52434A57) BeginCircleJettonWalletResolution {
    queryId: uint64
}


// ------------------------------------------------------------------
// Standard Jetton TON
//
// transfer_notification#7362d09c
// query_id:uint64
// amount:(VarUInteger 16)
// sender:MsgAddress
// forward_payload:(Either Cell ^Cell)
// ------------------------------------------------------------------

struct (0x7362d09c) JettonTransferNotification {
    queryId: uint64
    jettonAmount: coins
    transferInitiator: address
    forwardPayload: RemainingBitsAndRefs
}


// ------------------------------------------------------------------
// Transitions du cercle
// ------------------------------------------------------------------

struct (0x4C4F434B) LockCircle {
    queryId: uint64
}

struct (0x41435456) ActivateCircle {
    queryId: uint64
}


// ------------------------------------------------------------------
// Préparation atomique d'un paiement bénéficiaire.
//
// PREP = 0x50524550
// ------------------------------------------------------------------

struct (0x50524550) PreparePayout {
    queryId: uint64
}


// ============================================================
// Payout dispatch
// ============================================================

struct (0x44495350) DispatchPayout {
    queryId: uint64
}

// ============================================================
// TEP-74 Jetton transfer
// ============================================================

struct (0x0f8a7ea5) AskToTransfer {
    queryId: uint64
    jettonAmount: coins
    transferRecipient: address
    sendExcessesTo: address?
    customPayload: cell?
    forwardTonAmount: coins
    forwardPayload: RemainingBitsAndRefs
}


// ============================================================
// RSLV = Resolve beneficiary Jetton wallet
// ============================================================

struct (0x52534C56) ResolvePayoutWallet {
    queryId: uint64
}


// ============================================================
// TEP-74 wallet discovery
// ============================================================

struct (0x2c76b973) RequestWalletAddress {
    queryId: uint64
    ownerAddress: address
    includeOwnerAddress: bool
}

struct (0xd1735400) ResponseWalletAddress {
    queryId: uint64
    jettonWalletAddress: address?
    ownerAddress: Cell<address>?
}


// ============================================================
// TEP-74 — successful transfer excesses
// ============================================================

struct (0xd53276db) ReturnExcessesBack {
    queryId: uint64
}



// ============================================================
// SETTLEMENT FINAL
// 0x53455454 = "SETT"
// ============================================================

struct (0x53455454) BeginSettlement {
    queryId: uint64
}



// ============================================================
// RETRY SETTLEMENT WALLET LOOKUP
// 0x5253544C = "RSTL"
// ============================================================

struct (0x5253544C) RetrySettlementWallet {
    queryId: uint64
}



// ============================================================
// DISPATCH FINAL SETTLEMENT
// 0x4453544C = "DSTL"
// ============================================================

struct (0x4453544C) DispatchSettlement {
    queryId: uint64
}



// ============================================================
// BEGIN PROTOCOL FEE WITHDRAWAL
// 0x46574545 = "FWEE"
// ============================================================

struct (0x46574545) BeginProtocolFeeWithdrawal {
    queryId: uint64
}



// ============================================================
// DISPATCH PROTOCOL FEE WITHDRAWAL
// 0x44465745 = "DFWE"
// ============================================================

struct (0x44465745) DispatchProtocolFeeWithdrawal {
    queryId: uint64
}



// ============================================================
// RETRY PROTOCOL FEE WALLET LOOKUP
// 0x52465745 = "RFWE"
// ============================================================

struct (0x52465745) RetryProtocolFeeWallet {
    queryId: uint64
}


// ============================================================
// TVM 256-BIT BOUNCE STRUCTS
// ============================================================

struct (0x0f8a7ea5) BouncedAskToTransfer {
    queryId: uint64
    jettonAmount: coins
}

struct (0x2c76b973) BouncedRequestWalletAddress {
    queryId: uint64
}

