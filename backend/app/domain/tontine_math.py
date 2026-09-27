from dataclasses import dataclass
from decimal import Decimal

BPS = Decimal("10000")


@dataclass(frozen=True)
class V1Config:
    """Paramètres canoniques de la tontine V1."""

    members: int = 10
    contribution: Decimal = Decimal("20")
    personal_bond: Decimal = Decimal("40")

    protocol_fee_bps: int = 250          # 2.5 %
    guarantee_release_bps: int = 5000    # 50 %
    p2p_premium_bps: int = 600           # 6 %

    @property
    def pot(self) -> Decimal:
        """Cagnotte brute distribuée à chaque tour."""
        return self.contribution * self.members


@dataclass(frozen=True)
class PayoutQuote:
    """Résultat financier calculé pour le bénéficiaire d'un tour."""

    round_number: int

    remaining_debt: Decimal
    escrow: Decimal
    coverage: Decimal

    gross_cash: Decimal

    protocol_fee: Decimal
    p2p_premium: Decimal
    protocol_guarantee_premium: Decimal

    net_cash: Decimal


def apply_bps(amount: Decimal, rate_bps: int) -> Decimal:
    """Applique un taux exprimé en basis points."""
    return amount * Decimal(rate_bps) / BPS


def remaining_debt(
    round_number: int,
    config: V1Config = V1Config(),
) -> Decimal:
    """
    Dette de cotisation restante après le paiement du tour courant.

    R_t = (N - t) * c
    """
    if round_number < 1 or round_number > config.members:
        raise ValueError(
            f"round_number doit être compris entre 1 et {config.members}"
        )

    return Decimal(config.members - round_number) * config.contribution


def required_escrow(
    round_number: int,
    p2p_guarantee: Decimal = Decimal("0"),
    protocol_guarantee: Decimal = Decimal("0"),
    config: V1Config = V1Config(),
) -> Decimal:
    """
    Séquestre minimal du bénéficiaire.

    E_t = max(
        0,
        R_t - D - 0.5 * (G_P + G_S)
    )
    """
    if p2p_guarantee < 0 or protocol_guarantee < 0:
        raise ValueError("Une garantie ne peut pas être négative.")

    debt = remaining_debt(round_number, config)

    total_guarantee = p2p_guarantee + protocol_guarantee

    if total_guarantee > debt:
        raise ValueError(
            "Les garanties cumulées ne peuvent pas dépasser "
            "la dette restante."
        )

    recognized_guarantee = apply_bps(
        total_guarantee,
        config.guarantee_release_bps,
    )

    escrow = debt - config.personal_bond - recognized_guarantee

    return max(Decimal("0"), escrow)


def quote_payout(
    round_number: int,
    p2p_guarantee: Decimal = Decimal("0"),
    protocol_guarantee: Decimal = Decimal("0"),
    protocol_premium_bps: int = 0,
    config: V1Config = V1Config(),
) -> PayoutQuote:
    """
    Calcule le paiement du bénéficiaire tout en vérifiant
    l'invariant financier fondamental :

        E + D + G_P + G_S >= R
    """

    debt = remaining_debt(round_number, config)

    escrow = required_escrow(
        round_number=round_number,
        p2p_guarantee=p2p_guarantee,
        protocol_guarantee=protocol_guarantee,
        config=config,
    )

    coverage = (
        escrow
        + config.personal_bond
        + p2p_guarantee
        + protocol_guarantee
    )

    if coverage < debt:
        raise RuntimeError(
            "Invariant violé : la dette restante n'est pas couverte."
        )

    gross_cash = config.pot - escrow

    protocol_fee = apply_bps(
        config.pot,
        config.protocol_fee_bps,
    )

    p2p_premium = apply_bps(
        p2p_guarantee,
        config.p2p_premium_bps,
    )

    protocol_guarantee_premium = apply_bps(
        protocol_guarantee,
        protocol_premium_bps,
    )

    net_cash = (
        gross_cash
        - protocol_fee
        - p2p_premium
        - protocol_guarantee_premium
    )

    return PayoutQuote(
        round_number=round_number,
        remaining_debt=debt,
        escrow=escrow,
        coverage=coverage,
        gross_cash=gross_cash,
        protocol_fee=protocol_fee,
        p2p_premium=p2p_premium,
        protocol_guarantee_premium=protocol_guarantee_premium,
        net_cash=net_cash,
    )


@dataclass(frozen=True)
class EscrowRelease:
    """Résultat d'une libération progressive du séquestre."""

    debt_before: Decimal
    debt_after: Decimal

    escrow_before: Decimal
    escrow_required_after: Decimal

    released_amount: Decimal


def required_escrow_for_debt(
    debt: Decimal,
    p2p_guarantee: Decimal = Decimal("0"),
    protocol_guarantee: Decimal = Decimal("0"),
    config: V1Config = V1Config(),
) -> Decimal:
    """
    Calcule le séquestre minimal à conserver pour une dette donnée.

    E = max(
        0,
        R - D - 0.5 * (G_P + G_S)
    )

    Contrairement au calcul initial du payout, une garantie déjà
    verrouillée peut devenir supérieure à la dette restante au fil
    du cycle. Ce n'est pas une erreur : cela crée temporairement
    une sur-couverture.
    """

    if debt < 0:
        raise ValueError("La dette restante ne peut pas être négative.")

    if p2p_guarantee < 0 or protocol_guarantee < 0:
        raise ValueError("Une garantie ne peut pas être négative.")

    total_guarantee = p2p_guarantee + protocol_guarantee

    recognized_guarantee = apply_bps(
        total_guarantee,
        config.guarantee_release_bps,
    )

    escrow = (
        debt
        - config.personal_bond
        - recognized_guarantee
    )

    return max(Decimal("0"), escrow)


def release_escrow_after_contribution(
    debt_before: Decimal,
    escrow_before: Decimal,
    p2p_guarantee: Decimal = Decimal("0"),
    protocol_guarantee: Decimal = Decimal("0"),
    config: V1Config = V1Config(),
) -> EscrowRelease:
    """
    Calcule le montant de séquestre libérable après qu'un
    bénéficiaire a payé une nouvelle cotisation.

    Chaque paiement normal réduit sa dette de `config.contribution`.
    """

    if debt_before <= 0:
        raise ValueError(
            "Aucune contribution future n'est due."
        )

    if escrow_before < 0:
        raise ValueError(
            "Le séquestre actuel ne peut pas être négatif."
        )

    debt_after = max(
        Decimal("0"),
        debt_before - config.contribution,
    )

    escrow_required_after = required_escrow_for_debt(
        debt=debt_after,
        p2p_guarantee=p2p_guarantee,
        protocol_guarantee=protocol_guarantee,
        config=config,
    )

    if escrow_before < escrow_required_after:
        raise RuntimeError(
            "Etat invalide : le séquestre actuel est inférieur "
            "au minimum nécessaire après contribution."
        )

    released_amount = (
        escrow_before - escrow_required_after
    )

    return EscrowRelease(
        debt_before=debt_before,
        debt_after=debt_after,
        escrow_before=escrow_before,
        escrow_required_after=escrow_required_after,
        released_amount=released_amount,
    )


@dataclass(frozen=True)
class PostPayoutLiquidation:
    """Résultat d'une liquidation après paiement de la cagnotte."""

    debt_to_cover: Decimal

    escrow_used: Decimal
    bond_used: Decimal
    p2p_guarantee_used: Decimal
    protocol_guarantee_used: Decimal

    total_covered: Decimal

    escrow_remaining: Decimal
    bond_remaining: Decimal
    p2p_guarantee_remaining: Decimal
    protocol_guarantee_remaining: Decimal


def liquidate_post_payout_default(
    debt_to_cover: Decimal,
    escrow: Decimal,
    personal_bond: Decimal,
    p2p_guarantee: Decimal = Decimal("0"),
    protocol_guarantee: Decimal = Decimal("0"),
) -> PostPayoutLiquidation:
    """
    Couvre une dette après défaut d'un membre ayant déjà
    reçu sa cagnotte.

    Cascade obligatoire :
        1. Escrow
        2. Personal Bond
        3. P2P Guarantee
        4. Protocol Guarantee
    """

    amounts = (
        debt_to_cover,
        escrow,
        personal_bond,
        p2p_guarantee,
        protocol_guarantee,
    )

    if any(amount < 0 for amount in amounts):
        raise ValueError(
            "Les montants de liquidation ne peuvent pas être négatifs."
        )

    available_coverage = (
        escrow
        + personal_bond
        + p2p_guarantee
        + protocol_guarantee
    )

    if available_coverage < debt_to_cover:
        raise RuntimeError(
            "Défaut non couvert : les protections disponibles "
            "sont inférieures à la dette restante."
        )

    remaining_debt = debt_to_cover

    escrow_used = min(escrow, remaining_debt)
    remaining_debt -= escrow_used

    bond_used = min(personal_bond, remaining_debt)
    remaining_debt -= bond_used

    p2p_used = min(p2p_guarantee, remaining_debt)
    remaining_debt -= p2p_used

    protocol_used = min(protocol_guarantee, remaining_debt)
    remaining_debt -= protocol_used

    total_covered = (
        escrow_used
        + bond_used
        + p2p_used
        + protocol_used
    )

    if remaining_debt != 0:
        raise RuntimeError(
            "Erreur interne : la liquidation n'a pas couvert "
            "la totalité de la dette."
        )

    return PostPayoutLiquidation(
        debt_to_cover=debt_to_cover,
        escrow_used=escrow_used,
        bond_used=bond_used,
        p2p_guarantee_used=p2p_used,
        protocol_guarantee_used=protocol_used,
        total_covered=total_covered,
        escrow_remaining=escrow - escrow_used,
        bond_remaining=personal_bond - bond_used,
        p2p_guarantee_remaining=p2p_guarantee - p2p_used,
        protocol_guarantee_remaining=(
            protocol_guarantee - protocol_used
        ),
    )


@dataclass(frozen=True)
class PrePayoutDefaultPlan:
    """Plan financier d'un défaut avant réception de la cagnotte."""

    assigned_round: int
    last_paid_round: int

    remaining_obligation: Decimal

    bond_used_before_payout: Decimal
    continuity_bridge: Decimal

    future_payout_forfeited: Decimal

    bond_used_after_payout: Decimal
    future_contributions_reserved: Decimal

    continuity_repayment: Decimal
    continuity_residue: Decimal

    bond_remaining: Decimal


def plan_pre_payout_default(
    assigned_round: int,
    last_paid_round: int,
    config: V1Config = V1Config(),
) -> PrePayoutDefaultPlan:
    """
    Calcule le traitement d'un membre qui fait défaut avant
    d'avoir reçu sa cagnotte.

    Exemple extrême V1 :
        position 10
        aucun tour payé
        caution = 40

        contributions nécessaires avant son payout = 200
        caution utilisée = 40
        ContinuityVault avance = 160
    """

    if assigned_round < 1 or assigned_round > config.members:
        raise ValueError(
            f"assigned_round doit être compris entre 1 et {config.members}"
        )

    if last_paid_round < 0:
        raise ValueError(
            "last_paid_round ne peut pas être négatif."
        )

    if last_paid_round >= assigned_round:
        raise ValueError(
            "Ce calcul concerne uniquement un défaut avant payout."
        )

    remaining_obligation = (
        Decimal(config.members - last_paid_round)
        * config.contribution
    )

    contributions_before_payout = (
        Decimal(assigned_round - last_paid_round)
        * config.contribution
    )

    bond_used_before = min(
        config.personal_bond,
        contributions_before_payout,
    )

    continuity_bridge = (
        contributions_before_payout
        - bond_used_before
    )

    bond_remaining = (
        config.personal_bond
        - bond_used_before
    )

    contributions_after_payout = (
        Decimal(config.members - assigned_round)
        * config.contribution
    )

    bond_used_after = min(
        bond_remaining,
        contributions_after_payout,
    )

    future_contributions_reserved = (
        contributions_after_payout
        - bond_used_after
    )

    bond_remaining -= bond_used_after

    future_payout_forfeited = config.pot

    amount_needed_from_future_payout = (
        continuity_bridge
        + future_contributions_reserved
    )

    if amount_needed_from_future_payout > future_payout_forfeited:
        raise RuntimeError(
            "La future cagnotte ne suffit pas à restaurer "
            "la continuité du cercle."
        )

    continuity_residue = (
        future_payout_forfeited
        - amount_needed_from_future_payout
    )

    return PrePayoutDefaultPlan(
        assigned_round=assigned_round,
        last_paid_round=last_paid_round,
        remaining_obligation=remaining_obligation,
        bond_used_before_payout=bond_used_before,
        continuity_bridge=continuity_bridge,
        future_payout_forfeited=future_payout_forfeited,
        bond_used_after_payout=bond_used_after,
        future_contributions_reserved=future_contributions_reserved,
        continuity_repayment=continuity_bridge,
        continuity_residue=continuity_residue,
        bond_remaining=bond_remaining,
    )


def required_continuity_capacity(
    assigned_rounds: tuple[int, ...],
    last_paid_round: int = 0,
    config: V1Config = V1Config(),
) -> Decimal:
    """
    Capital de pont nécessaire pour plusieurs défauts
    pré-payout simultanés.
    """

    total = Decimal("0")

    for assigned_round in assigned_rounds:
        plan = plan_pre_payout_default(
            assigned_round=assigned_round,
            last_paid_round=last_paid_round,
            config=config,
        )

        total += plan.continuity_bridge

    return total
