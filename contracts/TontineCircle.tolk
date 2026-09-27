import "tontineTypes"

type AllowedMessage = AddMember;

contract TontineCircle {
    author: "Tontine Protocol V1"
    version: "0.2.0"
    description: "Core tontine circle contract"
    storage: TontineStorage
    incomingMessages: AllowedMessage
}

fun onInternalMessage(in: InMessage) {
    // Le déploiement Acton envoie un message interne vide.
    // Il doit être accepté avant toute lecture d'opcode.
    if (in.body.isEmpty()) {
        return;
    }

    if (in.body.remainingBitsCount() < 32) {
        throw TontineErrors.InvalidMessage;
    }

    // Lecture de l'opcode sans consommer le body.
    val op = in.body.preloadUint(32);

    // ----------------------------------------------------------
    // ADD MEMBER
    // ----------------------------------------------------------
    if (op == 0x41444D42) {
        val msg = lazy AddMember.fromSlice(in.body);
        var storage = lazy TontineStorage.load();

        assert (in.senderAddress == storage.controller)
            throw TontineErrors.NotController;

        assert (storage.state == 1)
            throw TontineErrors.InvalidState;

        assert (storage.registeredCount < storage.memberCount)
            throw TontineErrors.CircleFull;

        assert (
            msg.assignedRound >= 1
            && msg.assignedRound <= storage.memberCount
        ) throw TontineErrors.InvalidAssignedRound;

        assert (!storage.members.exists(msg.wallet))
            throw TontineErrors.MemberAlreadyExists;

        assert (!storage.roundOwners.exists(msg.assignedRound))
            throw TontineErrors.RoundAlreadyAssigned;

        val initialDebt: uint64 =
            storage.contributionAmount
            * (storage.memberCount as uint64);

        val member = MemberPosition {
            memberId: msg.memberId,
            assignedRound: msg.assignedRound,
            status: 1,

            totalContributed: 0,
            remainingDebt: initialDebt,

            bondLocked: 0,
            escrowLocked: 0,

            p2pGuaranteeActive: 0,
            protocolGuaranteeActive: 0,

            beneficiaryPaid: false,
            defaultDeclared: false,
            lastContributionRound: 0,
        };

        storage.members.set(msg.wallet, member);
        storage.roundOwners.set(
            msg.assignedRound,
            msg.wallet,
        );

        storage.registeredCount += 1;
        storage.save();

        return;
    }

    // ----------------------------------------------------------
    // SET CIRCLE JETTON WALLET
    // 0x53544A57 = "STJW"
    // Permet de configurer l'adresse du JettonWallet propre au cercle
    // après le calcul de l'adresse du contrat (résout la dépendance circulaire TVM).
    // Accessible uniquement par le contrôleur en état OPEN avant tout dépôt.
    // ----------------------------------------------------------
    if (op == 0x53544A57) {
        val msg = lazy SetCircleJettonWallet.fromSlice(in.body);
        var storage = lazy TontineStorage.load();

        assert (in.senderAddress == storage.controller)
            throw TontineErrors.NotController;

        assert (storage.state == 1)
            throw TontineErrors.InvalidState;

        assert (storage.fundedBondCount == 0)
            throw TontineErrors.InvalidState;

        storage.usdtWallet = msg.wallet;
        storage.save();

        return;
    }

    // ----------------------------------------------------------
    // JETTON TRANSFER NOTIFICATION
    // transfer_notification#7362d09c
    // ----------------------------------------------------------
    if (op == 0x7362d09c) {
        val msg =
            lazy JettonTransferNotification.fromSlice(in.body);

        var storage = lazy TontineStorage.load();

        // Seul le Jetton Wallet USDT officiel du cercle
        // peut notifier un transfert.
        assert (in.senderAddress == storage.usdtWallet)
            throw TontineErrors.UnauthorizedJettonWallet;

        assert (
            storage.members.exists(msg.transferInitiator)
        ) throw TontineErrors.MemberNotFound;

        var member = storage.members.mustGet(
            msg.transferInitiator,
            TontineErrors.MemberNotFound
        );

        // ======================================================
        // OPEN : financement de la caution personnelle
        // ======================================================
        if (storage.state == 1) {
            assert (member.bondLocked == 0)
                throw TontineErrors.BondAlreadyFunded;

            assert (
                msg.jettonAmount == storage.personalBond
            ) throw TontineErrors.InvalidBondAmount;

            member.bondLocked = storage.personalBond;

            // 2 = FUNDED_BOND
            member.status = 2;

            storage.members.set(
                msg.transferInitiator,
                member,
            );

            storage.fundedBondCount += 1;
            storage.save();

            return;
        }

        // ======================================================
        // ACTIVE : cotisation du round courant
        // ======================================================
        if (storage.state == 4) {
            assert (
                member.bondLocked == storage.personalBond
            ) throw TontineErrors.MemberBondNotFunded;

            assert (
                msg.jettonAmount == storage.contributionAmount
            ) throw TontineErrors.InvalidContributionAmount;

            assert (
                member.lastContributionRound != storage.currentRound
            ) throw TontineErrors.ContributionAlreadyPaid;

            assert (
                member.remainingDebt >= storage.contributionAmount
            ) throw TontineErrors.NoRemainingDebt;

            member.totalContributed += storage.contributionAmount;
            member.remainingDebt -= storage.contributionAmount;
            member.lastContributionRound = storage.currentRound;

            storage.roundContributionCount += 1;
            storage.roundCollected += storage.contributionAmount;

            storage.members.set(
                msg.transferInitiator,
                member,
            );

            storage.save();
            return;
        }

        throw TontineErrors.InvalidState;
    }

    // ----------------------------------------------------------
    // LOCK CIRCLE
    //
    // OPEN -> LOCKED
    // Seulement lorsque les 10 membres sont enregistrés
    // ET que les 10 cautions sont réellement financées.
    // ----------------------------------------------------------
    if (op == 0x4C4F434B) {
        var storage = lazy TontineStorage.load();

        assert (in.senderAddress == storage.controller)
            throw TontineErrors.NotController;

        assert (storage.state == 1)
            throw TontineErrors.InvalidState;

        assert (
            storage.registeredCount == storage.memberCount
        ) throw TontineErrors.CircleNotFullyRegistered;

        assert (
            storage.fundedBondCount == storage.memberCount
        ) throw TontineErrors.BondsNotFullyFunded;

        // 3 = LOCKED
        storage.state = 3;

        storage.save();
        return;
    }

    // ----------------------------------------------------------
    // ACTIVATE CIRCLE
    //
    // LOCKED -> ACTIVE
    // Le premier round devient actif.
    // ----------------------------------------------------------
    if (op == 0x41435456) {
        var storage = lazy TontineStorage.load();

        assert (in.senderAddress == storage.controller)
            throw TontineErrors.NotController;

        assert (storage.state == 3)
            throw TontineErrors.InvalidState;

        // 4 = ACTIVE
        storage.state = 4;
        storage.currentRound = 1;

        storage.save();
        return;
    }

    // ----------------------------------------------------------
    // PREPARE PAYOUT
    //
    // Le paiement est réservé comptablement avant tout
    // transfert Jetton sortant.
    // ----------------------------------------------------------
    if (op == 0x50524550) {
        val msg = lazy PreparePayout.fromSlice(in.body);
        var storage = lazy TontineStorage.load();
        var payout = storage.payout.load();
        var protocolState = storage.protocolState.load();

        assert (in.senderAddress == storage.controller)
            throw TontineErrors.NotController;

        assert (storage.state == 4)
            throw TontineErrors.InvalidState;

        assert (msg.queryId > protocolState.lastOperationQueryId)
            throw TontineErrors.ReplayedQueryId;

        assert (!payout.payoutPending)
            throw TontineErrors.PayoutAlreadyPending;

        assert (
            storage.roundContributionCount == storage.memberCount
        ) throw TontineErrors.RoundNotFullyFunded;

        val beneficiary = storage.roundOwners.mustGet(
            storage.currentRound,
            TontineErrors.MemberNotFound
        );

        var member = storage.members.mustGet(
            beneficiary,
            TontineErrors.MemberNotFound
        );

        assert (!member.beneficiaryPaid)
            throw TontineErrors.BeneficiaryAlreadyPaid;

        // ------------------------------------------------------
        // Escrow requis
        // E = max(0, R - D - 50% * garanties)
        // ------------------------------------------------------

        val totalGuarantees: uint64 =
            member.p2pGuaranteeActive
            + member.protocolGuaranteeActive;

        val recognizedGuarantees: uint64 =
            (totalGuarantees * 5000) / 10000;

        val coverageOutsideEscrow: uint64 =
            member.bondLocked
            + recognizedGuarantees;

        var escrow: uint64 = 0;

        if (member.remainingDebt > coverageOutsideEscrow) {
            escrow =
                member.remainingDebt
                - coverageOutsideEscrow;
        }

        // ------------------------------------------------------
        // Frais protocole
        // ------------------------------------------------------

        val fee: uint64 = (
            storage.roundCollected
            * (storage.protocolFeeBps as uint64)
        ) / 10000;

        assert (
            storage.roundCollected >= escrow + fee
        ) throw TontineErrors.InvalidPayoutMath;

        val netPayout: uint64 =
            storage.roundCollected
            - escrow
            - fee;

        // ------------------------------------------------------
        // Réservation financière atomique
        // ------------------------------------------------------

        member.escrowLocked = escrow;

        storage.members.set(
            beneficiary,
            member,
        );

        payout.protocolFeesAccrued += fee;

        payout.payoutPending = true;
        payout.beneficiaryWalletLookupPending = false;
        payout.beneficiaryJettonWallet = null;
        payout.pendingPayoutRound = storage.currentRound;
        payout.pendingPayoutAmount = netPayout;
        payout.pendingPayoutEscrow = escrow;
        payout.pendingPayoutFee = fee;
        payout.pendingPayoutQueryId = msg.queryId;

        protocolState.lastOperationQueryId = msg.queryId;
        storage.protocolState = protocolState.toCell();

        storage.payout = payout.toCell();
        storage.save();

        return;
    }

    // ======================================================
    // DISPATCH PAYOUT
    // ======================================================
    // ======================================================
    // RESOLVE BENEFICIARY JETTON WALLET
    // ======================================================
    if (op == 0x52534C56) {
        val msg = lazy ResolvePayoutWallet.fromSlice(in.body);

        var storage = lazy TontineStorage.load();
        var payout = storage.payout.load();
        val config = storage.protocolState.load().jettonMasterConfig.load();

        assert (in.senderAddress == storage.controller)
            throw TontineErrors.NotController;

        assert (storage.state == 4)
            throw TontineErrors.InvalidState;

        assert (payout.payoutPending)
            throw TontineErrors.PayoutNotPending;

        assert (!payout.payoutDispatched)
            throw TontineErrors.PayoutAlreadyDispatched;

        assert (
            msg.queryId == payout.pendingPayoutQueryId
        ) throw TontineErrors.PayoutQueryMismatch;

        assert (!payout.beneficiaryWalletLookupPending)
            throw TontineErrors.WalletLookupAlreadyPending;

        assert (payout.beneficiaryJettonWallet == null)
            throw TontineErrors.WalletAlreadyResolved;

        val beneficiary = storage.roundOwners.mustGet(
            payout.pendingPayoutRound,
            TontineErrors.MemberNotFound
        );

        val lookupMsg = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: grams("0.05"),
            dest: config.usdtMaster,
            body: RequestWalletAddress {
                queryId: payout.pendingPayoutQueryId,
                ownerAddress: beneficiary,
                includeOwnerAddress: true,
            },
        });

        lookupMsg.send(SEND_MODE_REGULAR);

        payout.beneficiaryWalletLookupPending = true;

        storage.payout = payout.toCell();
        storage.save();

        return;
    }


    // ======================================================
    // RESPONSE FROM AUTHORITATIVE USDT MASTER
    // ======================================================
    if (op == 0xd1735400) {
        val msg =
            lazy ResponseWalletAddress.fromSlice(in.body);

        var storage =
            lazy TontineStorage.load();

        var payout =
            storage.payout.load();

        var protocolState =
            storage.protocolState.load();

        var settlement =
            protocolState.settlement.load();

        var feeState =
            protocolState.feeState.load();

        val config =
            protocolState.jettonMasterConfig.load();

        // ====================================================
        // SOURCE AUTHENTIQUE
        // ====================================================

        assert (
            in.senderAddress == config.usdtMaster
        ) throw TontineErrors.UnauthorizedJettonWallet;


        // ====================================================
        // A. PAYOUT DE ROUND
        // ====================================================

        if (
            payout.payoutPending
            && payout.beneficiaryWalletLookupPending
        ) {
            assert (
                msg.queryId
                == payout.pendingPayoutQueryId
            ) throw TontineErrors.PayoutQueryMismatch;

            assert (
                msg.ownerAddress != null
            ) throw TontineErrors.JettonWalletOwnerMismatch;

            val expectedOwner =
                storage.roundOwners.mustGet(
                    payout.pendingPayoutRound,
                    TontineErrors.MemberNotFound
                );

            assert (
                msg.ownerAddress!.load()
                == expectedOwner
            ) throw TontineErrors.JettonWalletOwnerMismatch;

            assert (
                msg.jettonWalletAddress != null
            ) throw TontineErrors.WalletNotResolved;

            payout.beneficiaryJettonWallet =
                msg.jettonWalletAddress;

            payout.beneficiaryWalletLookupPending =
                false;

            storage.payout =
                payout.toCell();

            storage.save();
            return;
        }


        // ====================================================
        // B. SETTLEMENT MEMBRE
        // ====================================================

        if (
            settlement.settlementPending
            && settlement.walletLookupPending
        ) {
            assert (
                msg.queryId == settlement.queryId
            ) throw TontineErrors.SettlementQueryMismatch;

            assert (
                settlement.memberAddress != null
            ) throw TontineErrors.SettlementNotEligible;

            assert (
                msg.ownerAddress != null
            ) throw TontineErrors.JettonWalletOwnerMismatch;

            assert (
                msg.ownerAddress!.load()
                == settlement.memberAddress!
            ) throw TontineErrors.JettonWalletOwnerMismatch;

            assert (
                msg.jettonWalletAddress != null
            ) throw TontineErrors.SettlementWalletNotResolved;

            settlement.memberJettonWallet =
                msg.jettonWalletAddress;

            settlement.walletLookupPending =
                false;

            protocolState.settlement =
                settlement.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }


        // ====================================================
        // C. RETRAIT DES FRAIS PROTOCOLE
        // ====================================================

        if (
            feeState.withdrawalPending
            && feeState.walletLookupPending
        ) {
            assert (
                msg.queryId == feeState.queryId
            ) throw TontineErrors.ProtocolFeeQueryMismatch;

            assert (
                msg.ownerAddress != null
            ) throw TontineErrors.JettonWalletOwnerMismatch;

            assert (
                msg.ownerAddress!.load()
                == config.protocolTreasury
            ) throw TontineErrors.JettonWalletOwnerMismatch;

            assert (
                msg.jettonWalletAddress != null
            ) throw TontineErrors.ProtocolFeeWalletNotResolved;

            feeState.treasuryJettonWallet =
                msg.jettonWalletAddress;

            feeState.walletLookupPending =
                false;

            protocolState.feeState =
                feeState.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }

        throw TontineErrors.InvalidState;
    }


    if (op == 0x44495350) {
        val msg = lazy DispatchPayout.fromSlice(in.body);

        var storage = lazy TontineStorage.load();
        var payout = storage.payout.load();

        assert (in.senderAddress == storage.controller)
            throw TontineErrors.NotController;

        assert (storage.state == 4)
            throw TontineErrors.InvalidState;

        assert (payout.payoutPending)
            throw TontineErrors.PayoutNotPending;

        assert (!payout.payoutDispatched)
            throw TontineErrors.PayoutAlreadyDispatched;

        assert (msg.queryId == payout.pendingPayoutQueryId)
            throw TontineErrors.PayoutQueryMismatch;

        assert (payout.beneficiaryJettonWallet != null)
            throw TontineErrors.WalletNotResolved;

        val beneficiary = storage.roundOwners.mustGet(
            payout.pendingPayoutRound,
            TontineErrors.MemberNotFound
        );

        // TEP-74:
        // bit 0 = forward_payload inline vide.
        val forwardPayload = beginCell()
            .storeBool(false)
            .toSlice();

        val transferMsg = AskToTransfer {
            queryId: payout.pendingPayoutQueryId,
            jettonAmount: payout.pendingPayoutAmount as coins,
            transferRecipient: beneficiary,
            sendExcessesTo: contract.getAddress(),
            customPayload: null,

            // 1 nanoton, convention Jetton pour notification.
            forwardTonAmount: grams("0.000000001"),

            forwardPayload,
        };

        val outgoing = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: 0,
            dest: storage.usdtWallet,
            body: transferMsg,
        });

        // Le TON envoyé par le contrôleur sert au gas Jetton.
        outgoing.send(
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE
            | SEND_MODE_BOUNCE_ON_ACTION_FAIL
        );

        // Important :
        // dispatched != paid.
        payout.payoutDispatched = true;
        payout.payoutDispatchedAt =
            blockchain.now() as uint64;

        storage.payout = payout.toCell();
        storage.save();

        return;
    }

    // ======================================================
    // JETTON EXCESSES — CONFIRMATION DU PAYOUT
    //
    // L'excesses est envoyé par le wallet Jetton bénéficiaire
    // après traitement réussi du transfert TEP-74.
    // ======================================================
    if (op == 0xd53276db) {
        val msg =
            lazy ReturnExcessesBack.fromSlice(in.body);

        var storage =
            lazy TontineStorage.load();

        var payout =
            storage.payout.load();

        var protocolState =
            storage.protocolState.load();

        var settlement =
            protocolState.settlement.load();

        var feeState =
            protocolState.feeState.load();

        // ======================================================
        // A. PAYOUT DE ROUND
        // ======================================================

        if (payout.payoutPending) {
            assert (payout.payoutDispatched)
                throw TontineErrors.PayoutNotDispatched;

            assert (
                payout.beneficiaryJettonWallet != null
            ) throw TontineErrors.WalletNotResolved;

            assert (
                in.senderAddress
                == payout.beneficiaryJettonWallet!
            ) throw TontineErrors.UnauthorizedJettonWallet;

            assert (
                msg.queryId
                == payout.pendingPayoutQueryId
            ) throw TontineErrors.PayoutQueryMismatch;

            assert (
                payout.pendingPayoutRound
                == storage.currentRound
            ) throw TontineErrors.PayoutRoundMismatch;

            val beneficiary =
                storage.roundOwners.mustGet(
                    payout.pendingPayoutRound,
                    TontineErrors.MemberNotFound
                );

            var member =
                storage.members.mustGet(
                    beneficiary,
                    TontineErrors.MemberNotFound
                );

            assert (!member.beneficiaryPaid)
                throw TontineErrors.BeneficiaryAlreadyPaid;

            val completedRound =
                payout.pendingPayoutRound;

            member.beneficiaryPaid = true;

            storage.members.set(
                beneficiary,
                member,
            );

            payout.payoutPending = false;
            payout.payoutDispatched = false;
            payout.payoutDispatchedAt = 0;

            payout.beneficiaryWalletLookupPending =
                false;

            payout.beneficiaryJettonWallet = null;

            payout.pendingPayoutRound = 0;
            payout.pendingPayoutAmount = 0;
            payout.pendingPayoutEscrow = 0;
            payout.pendingPayoutFee = 0;
            payout.pendingPayoutQueryId = 0;

            storage.roundContributionCount = 0;
            storage.roundCollected = 0;

            if (completedRound < storage.memberCount) {
                storage.currentRound =
                    completedRound + 1;
            } else {
                storage.state = 5;
            }

            storage.payout =
                payout.toCell();

            storage.save();
            return;
        }

        // ======================================================
        // B. SETTLEMENT MEMBRE
        // ======================================================

        if (settlement.settlementPending) {
            assert (storage.state == 5)
                throw TontineErrors.InvalidState;

            assert (settlement.settlementDispatched)
                throw TontineErrors.SettlementNotDispatched;

            assert (
                settlement.memberAddress != null
            ) throw TontineErrors.SettlementNotEligible;

            assert (
                settlement.memberJettonWallet != null
            ) throw TontineErrors.SettlementWalletNotResolved;

            assert (
                in.senderAddress
                == settlement.memberJettonWallet!
            ) throw TontineErrors.UnauthorizedJettonWallet;

            assert (
                msg.queryId == settlement.queryId
            ) throw TontineErrors.SettlementQueryMismatch;

            val memberAddress =
                settlement.memberAddress!;

            var member =
                storage.members.mustGet(
                    memberAddress,
                    TontineErrors.MemberNotFound
                );

            assert (member.remainingDebt == 0)
                throw TontineErrors.SettlementNotEligible;

            assert (member.beneficiaryPaid)
                throw TontineErrors.SettlementNotEligible;

            val lockedAmount: uint64 =
                member.bondLocked
                + member.escrowLocked;

            assert (
                lockedAmount == settlement.amount
            ) throw TontineErrors.SettlementAmountMismatch;

            assert (lockedAmount > 0)
                throw TontineErrors.SettlementNothingToClaim;

            member.bondLocked = 0;
            member.escrowLocked = 0;

            storage.members.set(
                memberAddress,
                member,
            );

            // Un membre ne compte comme settled qu'après
            // confirmation Jetton authentifiée et libération
            // effective de son bond + escrow.
            assert (
                protocolState.memberSettlementsCompleted
                < storage.memberCount
            ) throw TontineErrors.SettlementCountInvariant;

            protocolState.memberSettlementsCompleted += 1;

            settlement.settlementPending = false;
            settlement.walletLookupPending = false;
            settlement.settlementDispatched = false;
            settlement.settlementDispatchedAt = 0;

            settlement.memberAddress = null;
            settlement.memberJettonWallet = null;

            settlement.amount = 0;
            settlement.queryId = 0;

            protocolState.settlement =
                settlement.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }

        // ======================================================
        // C. RETRAIT DES FRAIS PROTOCOLE
        // ======================================================

        if (feeState.withdrawalPending) {
            assert (storage.state == 5)
                throw TontineErrors.InvalidState;

            assert (feeState.withdrawalDispatched)
                throw TontineErrors.ProtocolFeeNotDispatched;

            assert (
                feeState.treasuryJettonWallet != null
            ) throw TontineErrors.ProtocolFeeWalletNotResolved;

            // Seul le wallet Jetton officiel de la
            // trésorerie peut confirmer le transfert.
            assert (
                in.senderAddress
                == feeState.treasuryJettonWallet!
            ) throw TontineErrors.UnauthorizedJettonWallet;

            assert (
                msg.queryId == feeState.queryId
            ) throw TontineErrors.ProtocolFeeQueryMismatch;

            assert (feeState.amount > 0)
                throw TontineErrors.ProtocolFeeNothingToWithdraw;

            // Dans cette V1, le retrait fige la totalité
            // des frais après COMPLETED. Aucun nouveau fee
            // ne peut donc apparaître pendant l'opération.
            assert (
                payout.protocolFeesAccrued
                == feeState.amount
            ) throw TontineErrors.ProtocolFeeAmountMismatch;

            // ==================================================
            // CONFIRMATION DEFINITIVE
            // ==================================================

            payout.protocolFeesAccrued -=
                feeState.amount;

            feeState.withdrawalPending = false;
            feeState.walletLookupPending = false;
            feeState.withdrawalDispatched = false;
            feeState.withdrawalDispatchedAt = 0;

            feeState.treasuryJettonWallet = null;

            feeState.amount = 0;
            feeState.queryId = 0;

            storage.payout =
                payout.toCell();

            protocolState.feeState =
                feeState.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }

        throw TontineErrors.InvalidState;
    }

    // ======================================================
    // BEGIN FINAL SETTLEMENT
    // ======================================================
    if (op == 0x53455454) {
        val msg = lazy BeginSettlement.fromSlice(in.body);

        var storage = lazy TontineStorage.load();
        var protocolState = storage.protocolState.load();
        var settlement = protocolState.settlement.load();

        val feeState =
            protocolState.feeState.load();

        // V1 : un settlement membre et un retrait des frais
        // ne peuvent pas être actifs simultanément.
        assert (!feeState.withdrawalPending)
            throw TontineErrors.ProtocolFeeOperationConflict;

        // Le settlement n'existe qu'après la fin des 10 rounds.
        assert (storage.state == 5)
            throw TontineErrors.InvalidState;

        // V1 : un seul settlement actif à la fois.
        assert (!settlement.settlementPending)
            throw TontineErrors.SettlementAlreadyPending;

        assert (msg.queryId > protocolState.lastOperationQueryId)
            throw TontineErrors.ReplayedQueryId;

        var member = storage.members.mustGet(
            in.senderAddress,
            TontineErrors.MemberNotFound
        );

        // Toutes les obligations du membre doivent être terminées.
        assert (member.remainingDebt == 0)
            throw TontineErrors.SettlementNotEligible;

        assert (member.beneficiaryPaid)
            throw TontineErrors.SettlementNotEligible;

        val amount: uint64 =
            member.bondLocked
            + member.escrowLocked;

        // Evite un deuxième claim après remboursement futur.
        assert (amount > 0)
            throw TontineErrors.SettlementNothingToClaim;

        // ------------------------------------------------------
        // Figer le claim AVANT résolution du wallet.
        // Aucun bond/escrow n'est encore libéré.
        // ------------------------------------------------------

        settlement.settlementPending = true;
        settlement.walletLookupPending = true;
        settlement.settlementDispatched = false;
        settlement.settlementDispatchedAt = 0;

        settlement.memberAddress =
            in.senderAddress;

        settlement.memberJettonWallet = null;
        settlement.amount = amount;
        settlement.queryId = msg.queryId;

        protocolState.lastOperationQueryId = msg.queryId;
        protocolState.settlement = settlement.toCell();

        storage.protocolState = protocolState.toCell();

        storage.save();

        // ------------------------------------------------------
        // Résolution du wallet USDT officiel du membre.
        // ------------------------------------------------------

        val config =
            storage.protocolState.load().jettonMasterConfig.load();

        val lookupMsg = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: grams("0.05"),
            dest: config.usdtMaster,
            body: RequestWalletAddress {
                queryId: msg.queryId,
                ownerAddress: in.senderAddress,
                includeOwnerAddress: true,
            },
        });

        lookupMsg.send(SEND_MODE_REGULAR);

        return;
    }

    // ======================================================
    // RETRY SETTLEMENT WALLET LOOKUP
    // ======================================================
    if (op == 0x5253544C) {
        val msg =
            lazy RetrySettlementWallet.fromSlice(in.body);

        var storage =
            lazy TontineStorage.load();

        assert (storage.state == 5)
            throw TontineErrors.InvalidState;

        var protocolState =
            storage.protocolState.load();

        var settlement =
            protocolState.settlement.load();

        assert (settlement.settlementPending)
            throw TontineErrors.SettlementNotPending;

        assert (settlement.memberAddress != null)
            throw TontineErrors.SettlementNotEligible;

        // Seul le membre propriétaire du settlement
        // peut relancer sa résolution.
        assert (
            in.senderAddress
            == settlement.memberAddress!
        ) throw TontineErrors.SettlementMemberMismatch;

        assert (
            msg.queryId == settlement.queryId
        ) throw TontineErrors.SettlementQueryMismatch;

        assert (!settlement.walletLookupPending)
            throw TontineErrors.SettlementWalletLookupAlreadyPending;

        assert (settlement.memberJettonWallet == null)
            throw TontineErrors.SettlementWalletAlreadyResolved;

        val config =
            protocolState.jettonMasterConfig.load();

        val lookupMsg = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: grams("0.05"),
            dest: config.usdtMaster,
            body: RequestWalletAddress {
                queryId: settlement.queryId,
                ownerAddress: settlement.memberAddress!,
                includeOwnerAddress: true,
            },
        });

        lookupMsg.send(SEND_MODE_REGULAR);

        settlement.walletLookupPending = true;

        protocolState.settlement =
            settlement.toCell();

        storage.protocolState =
            protocolState.toCell();

        storage.save();

        return;
    }

    // ======================================================
    // DISPATCH FINAL SETTLEMENT
    // ======================================================
    if (op == 0x4453544C) {
        val msg =
            lazy DispatchSettlement.fromSlice(in.body);

        var storage =
            lazy TontineStorage.load();

        assert (storage.state == 5)
            throw TontineErrors.InvalidState;

        var protocolState =
            storage.protocolState.load();

        var settlement =
            protocolState.settlement.load();

        assert (settlement.settlementPending)
            throw TontineErrors.SettlementNotPending;

        assert (settlement.memberAddress != null)
            throw TontineErrors.SettlementNotEligible;

        // Seul le membre propriétaire du claim peut
        // déclencher son remboursement.
        assert (
            in.senderAddress
            == settlement.memberAddress!
        ) throw TontineErrors.SettlementMemberMismatch;

        assert (
            msg.queryId == settlement.queryId
        ) throw TontineErrors.SettlementQueryMismatch;

        assert (!settlement.walletLookupPending)
            throw TontineErrors.SettlementWalletNotResolved;

        assert (settlement.memberJettonWallet != null)
            throw TontineErrors.SettlementWalletNotResolved;

        assert (!settlement.settlementDispatched)
            throw TontineErrors.SettlementAlreadyDispatched;

        assert (settlement.amount > 0)
            throw TontineErrors.SettlementNothingToClaim;

        val member =
            settlement.memberAddress!;

        val forwardPayload = beginCell()
            .storeBool(false)
            .toSlice();

        val transferMsg = AskToTransfer {
            queryId: settlement.queryId,
            jettonAmount: settlement.amount as coins,
            transferRecipient: member,
            sendExcessesTo: contract.getAddress(),
            customPayload: null,
            forwardTonAmount: grams("0.000000001"),
            forwardPayload,
        };

        val outgoing = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: 0,
            dest: storage.usdtWallet,
            body: transferMsg,
        });

        outgoing.send(
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE
            | SEND_MODE_BOUNCE_ON_ACTION_FAIL
        );

        // Important :
        // dispatched != settled.
        //
        // bondLocked et escrowLocked restent inchangés
        // jusqu'à l'excesses authentifié.
        settlement.settlementDispatched = true;
        settlement.settlementDispatchedAt =
            blockchain.now() as uint64;

        protocolState.settlement =
            settlement.toCell();

        storage.protocolState =
            protocolState.toCell();

        storage.save();

        return;
    }

    // ======================================================
    // BEGIN PROTOCOL FEE WITHDRAWAL
    // ======================================================
    if (op == 0x46574545) {
        val msg =
            lazy BeginProtocolFeeWithdrawal.fromSlice(in.body);

        var storage =
            lazy TontineStorage.load();

        // Les frais sont retirable uniquement après
        // la fin complète des dix rounds.
        assert (storage.state == 5)
            throw TontineErrors.InvalidState;

        var payout =
            storage.payout.load();

        var protocolState =
            storage.protocolState.load();

        val settlement =
            protocolState.settlement.load();

        var feeState =
            protocolState.feeState.load();

        val config =
            protocolState.jettonMasterConfig.load();

        // Seule l'adresse de trésorerie immuable peut
        // ouvrir ce retrait.
        assert (
            in.senderAddress
            == config.protocolTreasury
        ) throw TontineErrors.UnauthorizedProtocolTreasury;

        assert (!feeState.withdrawalPending)
            throw TontineErrors.ProtocolFeeWithdrawalAlreadyPending;

        assert (msg.queryId > protocolState.lastOperationQueryId)
            throw TontineErrors.ReplayedQueryId;

        // V1 : sérialisation avec les settlements membres.
        assert (!settlement.settlementPending)
            throw TontineErrors.ProtocolFeeOperationConflict;

        // Les actifs des membres sont prioritaires.
        // Aucun fee ne peut sortir avant le settlement
        // définitif des 10 membres.
        assert (
            protocolState.memberSettlementsCompleted
            == storage.memberCount
        ) throw TontineErrors.ProtocolFeeMembersNotSettled;

        assert (payout.protocolFeesAccrued > 0)
            throw TontineErrors.ProtocolFeeNothingToWithdraw;

        // ------------------------------------------------------
        // Figer le montant AVANT résolution du wallet.
        //
        // protocolFeesAccrued n'est PAS diminué ici.
        // ------------------------------------------------------

        feeState.withdrawalPending = true;
        feeState.walletLookupPending = true;
        feeState.withdrawalDispatched = false;
        feeState.withdrawalDispatchedAt = 0;

        feeState.treasuryJettonWallet = null;

        feeState.amount =
            payout.protocolFeesAccrued;

        feeState.queryId =
            msg.queryId;

        protocolState.lastOperationQueryId = msg.queryId;
        protocolState.feeState =
            feeState.toCell();

        storage.protocolState =
            protocolState.toCell();

        storage.save();

        // ------------------------------------------------------
        // Résoudre le wallet USDT officiel de la trésorerie.
        // ------------------------------------------------------

        val lookupMsg = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: grams("0.05"),
            dest: config.usdtMaster,
            body: RequestWalletAddress {
                queryId: msg.queryId,
                ownerAddress: config.protocolTreasury,
                includeOwnerAddress: true,
            },
        });

        lookupMsg.send(SEND_MODE_REGULAR);

        return;
    }

    // ======================================================
    // DISPATCH PROTOCOL FEE WITHDRAWAL
    // ======================================================
    if (op == 0x44465745) {
        val msg =
            lazy DispatchProtocolFeeWithdrawal.fromSlice(in.body);

        var storage =
            lazy TontineStorage.load();

        assert (storage.state == 5)
            throw TontineErrors.InvalidState;

        var protocolState =
            storage.protocolState.load();

        var feeState =
            protocolState.feeState.load();

        val config =
            protocolState.jettonMasterConfig.load();

        // Seule la trésorerie officielle peut déclencher
        // son transfert.
        assert (
            in.senderAddress
            == config.protocolTreasury
        ) throw TontineErrors.UnauthorizedProtocolTreasury;

        assert (feeState.withdrawalPending)
            throw TontineErrors.ProtocolFeeWithdrawalNotPending;

        assert (
            msg.queryId == feeState.queryId
        ) throw TontineErrors.ProtocolFeeQueryMismatch;

        assert (!feeState.walletLookupPending)
            throw TontineErrors.ProtocolFeeWalletNotResolved;

        assert (
            feeState.treasuryJettonWallet != null
        ) throw TontineErrors.ProtocolFeeWalletNotResolved;

        assert (!feeState.withdrawalDispatched)
            throw TontineErrors.ProtocolFeeAlreadyDispatched;

        assert (feeState.amount > 0)
            throw TontineErrors.ProtocolFeeNothingToWithdraw;

        val forwardPayload = beginCell()
            .storeBool(false)
            .toSlice();

        val transferMsg = AskToTransfer {
            queryId: feeState.queryId,
            jettonAmount: feeState.amount as coins,
            transferRecipient:
                config.protocolTreasury,
            sendExcessesTo:
                contract.getAddress(),
            customPayload: null,
            forwardTonAmount: grams("0.000000001"),
            forwardPayload,
        };

        val outgoing = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: 0,
            dest: storage.usdtWallet,
            body: transferMsg,
        });

        outgoing.send(
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE
            | SEND_MODE_BOUNCE_ON_ACTION_FAIL
        );

        // IMPORTANT :
        // dispatched != withdrawal finalized.
        //
        // protocolFeesAccrued reste intact jusqu'à
        // réception d'un excesses authentifié.
        feeState.withdrawalDispatched = true;
        feeState.withdrawalDispatchedAt =
            blockchain.now() as uint64;

        protocolState.feeState =
            feeState.toCell();

        storage.protocolState =
            protocolState.toCell();

        storage.save();

        return;
    }

    // ======================================================
    // RETRY PROTOCOL FEE WALLET LOOKUP
    // ======================================================
    if (op == 0x52465745) {
        val msg =
            lazy RetryProtocolFeeWallet.fromSlice(in.body);

        var storage =
            lazy TontineStorage.load();

        assert (storage.state == 5)
            throw TontineErrors.InvalidState;

        var protocolState =
            storage.protocolState.load();

        var feeState =
            protocolState.feeState.load();

        val config =
            protocolState.jettonMasterConfig.load();

        assert (
            in.senderAddress == config.protocolTreasury
        ) throw TontineErrors.UnauthorizedProtocolTreasury;

        assert (feeState.withdrawalPending)
            throw TontineErrors.ProtocolFeeWithdrawalNotPending;

        assert (
            msg.queryId == feeState.queryId
        ) throw TontineErrors.ProtocolFeeQueryMismatch;

        assert (!feeState.walletLookupPending)
            throw TontineErrors.ProtocolFeeWalletLookupAlreadyPending;

        assert (
            feeState.treasuryJettonWallet == null
        ) throw TontineErrors.ProtocolFeeWalletAlreadyResolved;

        val lookupMsg = createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            value: grams("0.05"),
            dest: config.usdtMaster,
            body: RequestWalletAddress {
                queryId: feeState.queryId,
                ownerAddress: config.protocolTreasury,
                includeOwnerAddress: true,
            },
        });

        lookupMsg.send(SEND_MODE_REGULAR);

        feeState.walletLookupPending = true;

        protocolState.feeState =
            feeState.toCell();

        storage.protocolState =
            protocolState.toCell();

        storage.save();

        return;
    }

    throw TontineErrors.InvalidMessage;
}


// ==================================================================
// CURRENT ROUND PAYOUT QUOTE
//
// Ces getters calculent le paiement mais ne déplacent encore
// aucun Jetton. Le transfert réel sera traité séparément.
// ==================================================================

get fun currentBeneficiary(): address {
    val storage = lazy TontineStorage.load();

    assert (storage.state == 4)
        throw TontineErrors.InvalidState;

    assert (
        storage.roundContributionCount == storage.memberCount
    ) throw TontineErrors.RoundNotFullyFunded;

    return storage.roundOwners.mustGet(
        storage.currentRound,
        TontineErrors.MemberNotFound
    );
}


get fun currentRequiredEscrow(): uint64 {
    val storage = lazy TontineStorage.load();

    assert (storage.state == 4)
        throw TontineErrors.InvalidState;

    assert (
        storage.roundContributionCount == storage.memberCount
    ) throw TontineErrors.RoundNotFullyFunded;

    val beneficiary = storage.roundOwners.mustGet(
        storage.currentRound,
        TontineErrors.MemberNotFound
    );

    val member = storage.members.mustGet(
        beneficiary,
        TontineErrors.MemberNotFound
    );

    // Reconnaissance prudente de 50 % des garanties.
    val totalGuarantees: uint64 =
        member.p2pGuaranteeActive
        + member.protocolGuaranteeActive;

    val recognizedGuarantees: uint64 =
        (totalGuarantees * 5000) / 10000;

    val coverageOutsideEscrow: uint64 =
        member.bondLocked + recognizedGuarantees;

    if (member.remainingDebt > coverageOutsideEscrow) {
        return member.remainingDebt - coverageOutsideEscrow;
    }

    return 0;
}


get fun currentProtocolFee(): uint64 {
    val storage = lazy TontineStorage.load();

    assert (storage.state == 4)
        throw TontineErrors.InvalidState;

    assert (
        storage.roundContributionCount == storage.memberCount
    ) throw TontineErrors.RoundNotFullyFunded;

    return (
        storage.roundCollected
        * (storage.protocolFeeBps as uint64)
    ) / 10000;
}


get fun currentNetPayout(): uint64 {
    val storage = lazy TontineStorage.load();

    assert (storage.state == 4)
        throw TontineErrors.InvalidState;

    assert (
        storage.roundContributionCount == storage.memberCount
    ) throw TontineErrors.RoundNotFullyFunded;

    val beneficiary = storage.roundOwners.mustGet(
        storage.currentRound,
        TontineErrors.MemberNotFound
    );

    val member = storage.members.mustGet(
        beneficiary,
        TontineErrors.MemberNotFound
    );

    val totalGuarantees: uint64 =
        member.p2pGuaranteeActive
        + member.protocolGuaranteeActive;

    val recognizedGuarantees: uint64 =
        (totalGuarantees * 5000) / 10000;

    val coverageOutsideEscrow: uint64 =
        member.bondLocked + recognizedGuarantees;

    var escrow: uint64 = 0;

    if (member.remainingDebt > coverageOutsideEscrow) {
        escrow =
            member.remainingDebt - coverageOutsideEscrow;
    }

    val fee: uint64 = (
        storage.roundCollected
        * (storage.protocolFeeBps as uint64)
    ) / 10000;

    assert (
        storage.roundCollected >= escrow + fee
    ) throw TontineErrors.InvalidPayoutMath;

    return storage.roundCollected - escrow - fee;
}


fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy TontineStorage.load();
    val config = storage.protocolState.load().jettonMasterConfig.load();

    // ========================================================
    // 1. Bounce du payout Jetton
    // ========================================================
    if (in.senderAddress == storage.usdtWallet) {
        if (in.bouncedBody.remainingBitsCount() < 32) {
            return;
        }

        in.bouncedBody.skipBouncedPrefix();

        val bouncedTransfer =
            lazy BouncedAskToTransfer.fromSlice(
                in.bouncedBody
            );

        var payout =
            storage.payout.load();

        var protocolState =
            storage.protocolState.load();

        var settlement =
            protocolState.settlement.load();

        var feeState =
            protocolState.feeState.load();

        val config =
            protocolState.jettonMasterConfig.load();

        // ====================================================
        // A. BOUNCE PAYOUT DE ROUND
        // ====================================================

        if (
            payout.payoutPending
            && payout.payoutDispatched
            && bouncedTransfer.queryId
                == payout.pendingPayoutQueryId
            && bouncedTransfer.jettonAmount
                == (payout.pendingPayoutAmount as coins)
        ) {
            payout.payoutDispatched = false;
            payout.payoutDispatchedAt = 0;

            storage.payout =
                payout.toCell();

            storage.save();
            return;
        }

        // ====================================================
        // B. BOUNCE SETTLEMENT MEMBRE
        // ====================================================

        if (
            settlement.settlementPending
            && settlement.settlementDispatched
            && bouncedTransfer.queryId
                == settlement.queryId
            && bouncedTransfer.jettonAmount
                == (settlement.amount as coins)
        ) {
            settlement.settlementDispatched = false;
            settlement.settlementDispatchedAt = 0;

            protocolState.settlement =
                settlement.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }

        // ====================================================
        // C. BOUNCE RETRAIT FRAIS PROTOCOLE
        // ====================================================

        if (
            feeState.withdrawalPending
            && feeState.withdrawalDispatched
            && bouncedTransfer.queryId
                == feeState.queryId
            && bouncedTransfer.jettonAmount
                == (feeState.amount as coins)
        ) {
            // Le transfert n'a pas abouti.
            // Les 50 USDT restent entièrement dus
            // et peuvent être redispatchés.
            feeState.withdrawalDispatched = false;
            feeState.withdrawalDispatchedAt = 0;

            protocolState.feeState =
                feeState.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }

        return;
    }

    // ========================================================
    // 2. Bounce de RequestWalletAddress vers le Master USDT
    // ========================================================
    if (in.senderAddress == config.usdtMaster) {
        if (in.bouncedBody.remainingBitsCount() < 32) {
            return;
        }

        in.bouncedBody.skipBouncedPrefix();

        val bouncedLookup =
            lazy BouncedRequestWalletAddress.fromSlice(
                in.bouncedBody
            );

        var payout =
            storage.payout.load();

        var protocolState =
            storage.protocolState.load();

        var settlement =
            protocolState.settlement.load();

        var feeState =
            protocolState.feeState.load();

        // ====================================================
        // A. PAYOUT
        // ====================================================

        if (
            payout.payoutPending
            && payout.beneficiaryWalletLookupPending
            && bouncedLookup.queryId
                == payout.pendingPayoutQueryId
        ) {
            payout.beneficiaryWalletLookupPending =
                false;

            storage.payout =
                payout.toCell();

            storage.save();
            return;
        }

        // ====================================================
        // B. SETTLEMENT MEMBRE
        // ====================================================

        if (
            settlement.settlementPending
            && settlement.walletLookupPending
            && bouncedLookup.queryId
                == settlement.queryId
        ) {
            settlement.walletLookupPending =
                false;

            protocolState.settlement =
                settlement.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }

        // ====================================================
        // C. FRAIS PROTOCOLE
        // ====================================================

        if (
            feeState.withdrawalPending
            && feeState.walletLookupPending
            && bouncedLookup.queryId
                == feeState.queryId
        ) {
            feeState.walletLookupPending =
                false;

            protocolState.feeState =
                feeState.toCell();

            storage.protocolState =
                protocolState.toCell();

            storage.save();
            return;
        }

        return;
    }

    throw TontineErrors.UnauthorizedJettonWallet;
}

get fun settlementPending(): bool {
    val storage = lazy TontineStorage.load();
    val protocolState = storage.protocolState.load();
    val settlement = protocolState.settlement.load();

    return settlement.settlementPending;
}

get fun settlementWalletLookupPending(): bool {
    val storage = lazy TontineStorage.load();
    val protocolState = storage.protocolState.load();
    val settlement = protocolState.settlement.load();

    return settlement.walletLookupPending;
}

get fun settlementDispatched(): bool {
    val storage = lazy TontineStorage.load();
    val protocolState = storage.protocolState.load();
    val settlement = protocolState.settlement.load();

    return settlement.settlementDispatched;
}

get fun settlementAmount(): uint64 {
    val storage = lazy TontineStorage.load();
    val protocolState = storage.protocolState.load();
    val settlement = protocolState.settlement.load();

    return settlement.amount;
}

get fun settlementMember(): address {
    val storage = lazy TontineStorage.load();
    val protocolState = storage.protocolState.load();
    val settlement = protocolState.settlement.load();

    assert (settlement.memberAddress != null)
        throw TontineErrors.SettlementNotEligible;

    return settlement.memberAddress!;
}

get fun settlementWalletResolved(): bool {
    val storage = lazy TontineStorage.load();
    val protocolState = storage.protocolState.load();
    val settlement = protocolState.settlement.load();

    return settlement.memberJettonWallet != null;
}

get fun settlementJettonWallet(): address {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val settlement =
        protocolState.settlement.load();

    assert (settlement.memberJettonWallet != null)
        throw TontineErrors.SettlementWalletNotResolved;

    return settlement.memberJettonWallet!;
}



get fun circleId(): uint64 {
    val storage = lazy TontineStorage.load();
    return storage.circleId;
}

get fun state(): uint8 {
    val storage = lazy TontineStorage.load();
    return storage.state;
}

get fun memberBeneficiaryPaid(
    memberAddress: address
): bool {
    val storage = lazy TontineStorage.load();

    val member = storage.members.mustGet(
        memberAddress,
        TontineErrors.MemberNotFound
    );

    return member.beneficiaryPaid;
}

get fun currentRound(): uint8 {
    val storage = lazy TontineStorage.load();
    return storage.currentRound;
}

get fun memberCount(): uint8 {
    val storage = lazy TontineStorage.load();
    return storage.memberCount;
}

get fun registeredCount(): uint8 {
    val storage = lazy TontineStorage.load();
    return storage.registeredCount;
}

get fun payoutBeneficiaryWalletLookupPending(): bool {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();

    return payout.beneficiaryWalletLookupPending;
}

get fun payoutBeneficiaryWalletResolved(): bool {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();

    return payout.beneficiaryJettonWallet != null;
}

get fun payoutBeneficiaryJettonWallet(): address {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();

    assert (payout.beneficiaryJettonWallet != null)
        throw TontineErrors.WalletNotResolved;

    return payout.beneficiaryJettonWallet!;
}

get fun usdtMasterAddress(): address {
    val storage = lazy TontineStorage.load();
    val config = storage.protocolState.load().jettonMasterConfig.load();
    return config.usdtMaster;
}

get fun jettonDispatchStaleAfterSeconds(): uint64 {
    return 3600;
}


get fun payoutDispatchedAt(): uint64 {
    val storage =
        lazy TontineStorage.load();

    return storage.payout.load().payoutDispatchedAt;
}

get fun payoutDispatchStale(): bool {
    val storage =
        lazy TontineStorage.load();

    val payout =
        storage.payout.load();

    if (!payout.payoutDispatched) {
        return false;
    }

    if (payout.payoutDispatchedAt == 0) {
        return false;
    }

    val now =
        blockchain.now() as uint64;

    return now >=
        payout.payoutDispatchedAt
        + (3600 as uint64);
}


get fun settlementDispatchedAt(): uint64 {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    return protocolState
        .settlement
        .load()
        .settlementDispatchedAt;
}

get fun settlementDispatchStale(): bool {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val settlement =
        protocolState.settlement.load();

    if (!settlement.settlementDispatched) {
        return false;
    }

    if (settlement.settlementDispatchedAt == 0) {
        return false;
    }

    val now =
        blockchain.now() as uint64;

    return now >=
        settlement.settlementDispatchedAt
        + (3600 as uint64);
}


get fun protocolFeeWithdrawalDispatchedAt(): uint64 {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    return protocolState
        .feeState
        .load()
        .withdrawalDispatchedAt;
}


get fun protocolFeeWithdrawalDispatchStale(): bool {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val feeState =
        protocolState.feeState.load();

    if (!feeState.withdrawalDispatched) {
        return false;
    }

    if (feeState.withdrawalDispatchedAt == 0) {
        return false;
    }

    val now =
        blockchain.now() as uint64;

    return now >=
        feeState.withdrawalDispatchedAt
        + (3600 as uint64);
}


get fun protocolTreasuryAddress(): address {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val config =
        protocolState.jettonMasterConfig.load();

    return config.protocolTreasury;
}


get fun payoutDispatched(): bool {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();
    return payout.payoutDispatched;
}

get fun payoutPending(): bool {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();
    return payout.payoutPending;
}

get fun pendingPayoutRound(): uint8 {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();
    return payout.pendingPayoutRound;
}

get fun pendingPayoutAmount(): uint64 {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();
    return payout.pendingPayoutAmount;
}

get fun pendingPayoutEscrow(): uint64 {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();
    return payout.pendingPayoutEscrow;
}

get fun pendingPayoutFee(): uint64 {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();
    return payout.pendingPayoutFee;
}

get fun memberSettlementsCompleted(): uint8 {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    return protocolState.memberSettlementsCompleted;
}


get fun protocolFeeWithdrawalPending(): bool {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val feeState =
        protocolState.feeState.load();

    return feeState.withdrawalPending;
}

get fun protocolFeeWalletLookupPending(): bool {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val feeState =
        protocolState.feeState.load();

    return feeState.walletLookupPending;
}

get fun protocolFeeWithdrawalDispatched(): bool {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val feeState =
        protocolState.feeState.load();

    return feeState.withdrawalDispatched;
}

get fun protocolFeeWithdrawalAmount(): uint64 {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val feeState =
        protocolState.feeState.load();

    return feeState.amount;
}

get fun protocolFeeWalletResolved(): bool {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val feeState =
        protocolState.feeState.load();

    return feeState.treasuryJettonWallet != null;
}

get fun protocolFeeTreasuryJettonWallet(): address {
    val storage =
        lazy TontineStorage.load();

    val protocolState =
        storage.protocolState.load();

    val feeState =
        protocolState.feeState.load();

    assert (
        feeState.treasuryJettonWallet != null
    ) throw TontineErrors.ProtocolFeeWalletNotResolved;

    return feeState.treasuryJettonWallet!;
}



get fun protocolFeesAccrued(): uint64 {
    val storage = lazy TontineStorage.load();
    val payout = storage.payout.load();
    return payout.protocolFeesAccrued;
}

get fun roundContributionCount(): uint8 {
    val storage = lazy TontineStorage.load();
    return storage.roundContributionCount;
}

get fun roundCollected(): uint64 {
    val storage = lazy TontineStorage.load();
    return storage.roundCollected;
}

get fun memberTotalContributed(wallet: address): uint64 {
    val storage = lazy TontineStorage.load();

    return storage.members.mustGet(
        wallet,
        TontineErrors.MemberNotFound
    ).totalContributed;
}

get fun memberLastContributionRound(wallet: address): uint8 {
    val storage = lazy TontineStorage.load();

    return storage.members.mustGet(
        wallet,
        TontineErrors.MemberNotFound
    ).lastContributionRound;
}

get fun fundedBondCount(): uint8 {
    val storage = lazy TontineStorage.load();
    return storage.fundedBondCount;
}

get fun contributionAmount(): uint64 {
    val storage = lazy TontineStorage.load();
    return storage.contributionAmount;
}

get fun personalBond(): uint64 {
    val storage = lazy TontineStorage.load();
    return storage.personalBond;
}

get fun protocolFeeBps(): uint16 {
    val storage = lazy TontineStorage.load();
    return storage.protocolFeeBps;
}

get fun memberExists(wallet: address): bool {
    val storage = lazy TontineStorage.load();
    return storage.members.exists(wallet);
}

get fun memberRemainingDebt(wallet: address): uint64 {
    val storage = lazy TontineStorage.load();

    return storage.members.mustGet(
        wallet,
        TontineErrors.MemberNotFound
    ).remainingDebt;
}

get fun memberEscrow(wallet: address): uint64 {
    val storage = lazy TontineStorage.load();

    return storage.members.mustGet(
        wallet,
        TontineErrors.MemberNotFound
    ).escrowLocked;
}

get fun memberSettlementDue(
    wallet: address
): uint64 {
    val storage = lazy TontineStorage.load();

    val member = storage.members.mustGet(
        wallet,
        TontineErrors.MemberNotFound
    );

    // Rien n'est libérable avant la fin complète.
    if (storage.state != 5) {
        return 0;
    }

    // Le settlement final ne concerne qu'un membre
    // ayant terminé ses obligations et reçu son payout.
    if (member.remainingDebt != 0) {
        return 0;
    }

    if (!member.beneficiaryPaid) {
        return 0;
    }

    return member.bondLocked + member.escrowLocked;
}

get fun memberBond(wallet: address): uint64 {
    val storage = lazy TontineStorage.load();

    return storage.members.mustGet(
        wallet,
        TontineErrors.MemberNotFound
    ).bondLocked;
}

get fun roundIsAssigned(roundNumber: uint8): bool {
    val storage = lazy TontineStorage.load();
    return storage.roundOwners.exists(roundNumber);
}

get fun memberStatus(wallet: address): uint8 {
    val storage = lazy TontineStorage.load();

    return storage.members.mustGet(
        wallet,
        TontineErrors.MemberNotFound
    ).status;
}

get fun lastOperationQueryId(): uint64 {
    val storage = lazy TontineStorage.load();
    return storage.protocolState.load().lastOperationQueryId;
}


