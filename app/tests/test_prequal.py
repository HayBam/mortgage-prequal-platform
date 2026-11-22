import pytest

from prequal import Application, evaluate, monthly_payment, qualifying_rate


def test_stress_test_adds_two_points():
    assert qualifying_rate(4.89) == pytest.approx(6.89)


def test_stress_test_floor_applies_to_low_rates():
    assert qualifying_rate(2.5) == 5.25


def test_monthly_payment_semi_annual_compounding():
    # 500,000 at 5% over 25 years, Canadian semi-annual compounding: about 2,908.02
    assert monthly_payment(500_000, 5.0, 25) == pytest.approx(2908.02, abs=0.5)


def test_strong_application_is_approved():
    app = Application(annual_income=150_000, loan_amount=450_000, contract_rate=4.5,
                      property_tax_annual=4_800, other_debt_monthly=300)
    decision = evaluate(app, gds_limit=0.39, tds_limit=0.44)
    assert decision.approved
    assert decision.reasons == []


def test_high_debt_application_is_declined_on_tds():
    app = Application(annual_income=90_000, loan_amount=500_000, contract_rate=4.5,
                      property_tax_annual=4_000, other_debt_monthly=1_500)
    decision = evaluate(app, gds_limit=0.39, tds_limit=0.44)
    assert not decision.approved
    assert any("TDS" in r for r in decision.reasons)
