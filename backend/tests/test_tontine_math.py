import unittest
from decimal import Decimal

from backend.app.domain.tontine_math import (
    remaining_debt,
    required_escrow,
    quote_payout,
)


class TestTontineMathV1(unittest.TestCase):

    def test_round_1_without_guarantee(self):
        quote = quote_payout(round_number=1)

        self.assertEqual(
            quote.remaining_debt,
            Decimal("180"),
        )

        self.assertEqual(
            quote.escrow,
            Decimal("140"),
        )

        self.assertEqual(
            quote.coverage,
            Decimal("180"),
        )

        self.assertEqual(
            quote.gross_cash,
            Decimal("60"),
        )

        self.assertEqual(
            quote.protocol_fee,
            Decimal("5"),
        )

        self.assertEqual(
            quote.net_cash,
            Decimal("55"),
        )

    def test_round_10_without_guarantee(self):
        quote = quote_payout(round_number=10)

        self.assertEqual(
            quote.remaining_debt,
            Decimal("0"),
        )

        self.assertEqual(
            quote.escrow,
            Decimal("0"),
        )

        self.assertEqual(
            quote.net_cash,
            Decimal("195"),
        )

    def test_round_1_with_p2p_guarantee(self):
        quote = quote_payout(
            round_number=1,
            p2p_guarantee=Decimal("60"),
        )

        self.assertEqual(
            quote.escrow,
            Decimal("110"),
        )

        self.assertEqual(
            quote.p2p_premium,
            Decimal("3.6"),
        )

        self.assertEqual(
            quote.net_cash,
            Decimal("81.4"),
        )


if __name__ == "__main__":
    unittest.main()


class TestEscrowReleaseV1(unittest.TestCase):

    def test_release_after_first_future_payment_without_guarantee(self):
        from backend.app.domain.tontine_math import (
            release_escrow_after_contribution,
        )

        result = release_escrow_after_contribution(
            debt_before=Decimal("180"),
            escrow_before=Decimal("140"),
        )

        self.assertEqual(result.debt_after, Decimal("160"))
        self.assertEqual(result.escrow_required_after, Decimal("120"))
        self.assertEqual(result.released_amount, Decimal("20"))

    def test_release_with_p2p_guarantee(self):
        from backend.app.domain.tontine_math import (
            release_escrow_after_contribution,
        )

        result = release_escrow_after_contribution(
            debt_before=Decimal("180"),
            escrow_before=Decimal("110"),
            p2p_guarantee=Decimal("60"),
        )

        self.assertEqual(result.debt_after, Decimal("160"))
        self.assertEqual(result.escrow_required_after, Decimal("90"))
        self.assertEqual(result.released_amount, Decimal("20"))

    def test_escrow_never_becomes_negative(self):
        from backend.app.domain.tontine_math import (
            release_escrow_after_contribution,
        )

        result = release_escrow_after_contribution(
            debt_before=Decimal("40"),
            escrow_before=Decimal("0"),
        )

        self.assertEqual(result.debt_after, Decimal("20"))
        self.assertEqual(result.escrow_required_after, Decimal("0"))
        self.assertEqual(result.released_amount, Decimal("0"))


class TestPostPayoutDefaultV1(unittest.TestCase):

    def test_default_without_guarantee(self):
        from backend.app.domain.tontine_math import (
            liquidate_post_payout_default,
        )

        result = liquidate_post_payout_default(
            debt_to_cover=Decimal("180"),
            escrow=Decimal("140"),
            personal_bond=Decimal("40"),
        )

        self.assertEqual(result.escrow_used, Decimal("140"))
        self.assertEqual(result.bond_used, Decimal("40"))
        self.assertEqual(result.total_covered, Decimal("180"))

    def test_default_with_p2p_guarantee(self):
        from backend.app.domain.tontine_math import (
            liquidate_post_payout_default,
        )

        result = liquidate_post_payout_default(
            debt_to_cover=Decimal("180"),
            escrow=Decimal("110"),
            personal_bond=Decimal("40"),
            p2p_guarantee=Decimal("60"),
        )

        self.assertEqual(result.escrow_used, Decimal("110"))
        self.assertEqual(result.bond_used, Decimal("40"))
        self.assertEqual(
            result.p2p_guarantee_used,
            Decimal("30"),
        )
        self.assertEqual(
            result.p2p_guarantee_remaining,
            Decimal("30"),
        )
        self.assertEqual(result.total_covered, Decimal("180"))

    def test_default_with_protocol_guarantee(self):
        from backend.app.domain.tontine_math import (
            liquidate_post_payout_default,
        )

        result = liquidate_post_payout_default(
            debt_to_cover=Decimal("180"),
            escrow=Decimal("90"),
            personal_bond=Decimal("40"),
            protocol_guarantee=Decimal("100"),
        )

        self.assertEqual(result.escrow_used, Decimal("90"))
        self.assertEqual(result.bond_used, Decimal("40"))
        self.assertEqual(
            result.protocol_guarantee_used,
            Decimal("50"),
        )
        self.assertEqual(
            result.protocol_guarantee_remaining,
            Decimal("50"),
        )

    def test_rejects_undercovered_default(self):
        from backend.app.domain.tontine_math import (
            liquidate_post_payout_default,
        )

        with self.assertRaises(RuntimeError):
            liquidate_post_payout_default(
                debt_to_cover=Decimal("180"),
                escrow=Decimal("50"),
                personal_bond=Decimal("40"),
            )


class TestPrePayoutDefaultV1(unittest.TestCase):

    def test_position_10_default_from_start(self):
        from backend.app.domain.tontine_math import (
            plan_pre_payout_default,
        )

        result = plan_pre_payout_default(
            assigned_round=10,
            last_paid_round=0,
        )

        self.assertEqual(
            result.remaining_obligation,
            Decimal("200"),
        )

        self.assertEqual(
            result.bond_used_before_payout,
            Decimal("40"),
        )

        self.assertEqual(
            result.continuity_bridge,
            Decimal("160"),
        )

        self.assertEqual(
            result.future_payout_forfeited,
            Decimal("200"),
        )

        self.assertEqual(
            result.continuity_repayment,
            Decimal("160"),
        )

        self.assertEqual(
            result.continuity_residue,
            Decimal("40"),
        )

    def test_position_10_after_round_1_paid(self):
        from backend.app.domain.tontine_math import (
            plan_pre_payout_default,
        )

        result = plan_pre_payout_default(
            assigned_round=10,
            last_paid_round=1,
        )

        self.assertEqual(
            result.remaining_obligation,
            Decimal("180"),
        )

        self.assertEqual(
            result.continuity_bridge,
            Decimal("140"),
        )

        self.assertEqual(
            result.continuity_residue,
            Decimal("60"),
        )

    def test_position_9_default_from_start(self):
        from backend.app.domain.tontine_math import (
            plan_pre_payout_default,
        )

        result = plan_pre_payout_default(
            assigned_round=9,
            last_paid_round=0,
        )

        self.assertEqual(
            result.continuity_bridge,
            Decimal("140"),
        )

        self.assertEqual(
            result.future_contributions_reserved,
            Decimal("20"),
        )

    def test_three_simultaneous_pre_payout_defaults(self):
        from backend.app.domain.tontine_math import (
            required_continuity_capacity,
        )

        capacity = required_continuity_capacity(
            assigned_rounds=(10, 9, 8),
            last_paid_round=0,
        )

        self.assertEqual(
            capacity,
            Decimal("420"),
        )


if __name__ == "__main__":
    unittest.main()


class TestProtocolInvariantsV1(unittest.TestCase):

    def test_all_rounds_without_guarantee_are_covered(self):
        from backend.app.domain.tontine_math import quote_payout

        for round_number in range(1, 11):
            with self.subTest(round_number=round_number):
                quote = quote_payout(round_number=round_number)

                self.assertGreaterEqual(
                    quote.coverage,
                    quote.remaining_debt,
                )

                self.assertGreaterEqual(
                    quote.escrow,
                    Decimal("0"),
                )

                self.assertGreaterEqual(
                    quote.net_cash,
                    Decimal("0"),
                )

    def test_guarantees_never_break_coverage(self):
        from backend.app.domain.tontine_math import (
            quote_payout,
            remaining_debt,
        )

        guarantee_values = (
            Decimal("0"),
            Decimal("20"),
            Decimal("40"),
            Decimal("60"),
        )

        for round_number in range(1, 11):
            debt = remaining_debt(round_number)

            for p2p in guarantee_values:
                for protocol in guarantee_values:
                    total_guarantee = p2p + protocol

                    if total_guarantee > debt:
                        continue

                    with self.subTest(
                        round_number=round_number,
                        p2p=p2p,
                        protocol=protocol,
                    ):
                        quote = quote_payout(
                            round_number=round_number,
                            p2p_guarantee=p2p,
                            protocol_guarantee=protocol,
                        )

                        self.assertGreaterEqual(
                            quote.coverage,
                            quote.remaining_debt,
                        )

                        self.assertGreaterEqual(
                            quote.escrow,
                            Decimal("0"),
                        )

    def test_more_valid_guarantee_never_increases_escrow(self):
        from backend.app.domain.tontine_math import required_escrow

        escrow_without_guarantee = required_escrow(
            round_number=1,
        )

        escrow_with_60 = required_escrow(
            round_number=1,
            p2p_guarantee=Decimal("60"),
        )

        escrow_with_100 = required_escrow(
            round_number=1,
            protocol_guarantee=Decimal("100"),
        )

        self.assertGreaterEqual(
            escrow_without_guarantee,
            escrow_with_60,
        )

        self.assertGreaterEqual(
            escrow_with_60,
            escrow_with_100,
        )

    def test_liquidation_never_uses_more_than_required(self):
        from backend.app.domain.tontine_math import (
            liquidate_post_payout_default,
        )

        result = liquidate_post_payout_default(
            debt_to_cover=Decimal("180"),
            escrow=Decimal("110"),
            personal_bond=Decimal("40"),
            p2p_guarantee=Decimal("60"),
            protocol_guarantee=Decimal("100"),
        )

        self.assertEqual(
            result.total_covered,
            Decimal("180"),
        )

        self.assertEqual(
            result.p2p_guarantee_used,
            Decimal("30"),
        )

        self.assertEqual(
            result.protocol_guarantee_used,
            Decimal("0"),
        )

        self.assertEqual(
            result.p2p_guarantee_remaining,
            Decimal("30"),
        )

        self.assertEqual(
            result.protocol_guarantee_remaining,
            Decimal("100"),
        )
