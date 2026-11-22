"""Mortgage pre-qualification rules.

Demo only. These are simplified Canadian lending rules used to give the
platform a realistic workload. They are not Haventree Bank's credit policy.

- GDS (Gross Debt Service): housing costs / gross monthly income.
- TDS (Total Debt Service): housing costs + other debts / gross monthly income.
- Stress test (OSFI Guideline B-20 style): the borrower must qualify at the
  higher of (contract rate + 2%) or the 5.25% floor.
- Canadian fixed-rate mortgages compound semi-annually, so the monthly rate
  is (1 + annual_rate / 2) ** (2 / 12) - 1.
"""

from dataclasses import dataclass

STRESS_TEST_BUFFER = 2.0  # percentage points added to the contract rate
STRESS_TEST_FLOOR = 5.25  # minimum qualifying rate, in percent


@dataclass(frozen=True)
class Application:
    annual_income: float
    loan_amount: float
    contract_rate: float  # annual rate in percent, e.g. 4.89
    amortization_years: int = 25
    property_tax_annual: float = 0.0
    heating_monthly: float = 100.0
    condo_fees_monthly: float = 0.0
    other_debt_monthly: float = 0.0


@dataclass(frozen=True)
class Decision:
    qualifying_rate: float
    monthly_payment: float
    gds_ratio: float
    tds_ratio: float
    gds_limit: float
    tds_limit: float
    approved: bool
    reasons: list[str]


def qualifying_rate(contract_rate: float) -> float:
    """Rate the borrower must be able to afford under the stress test."""
    return max(contract_rate + STRESS_TEST_BUFFER, STRESS_TEST_FLOOR)


def monthly_payment(principal: float, annual_rate_pct: float, years: int) -> float:
    """Blended principal and interest payment with semi-annual compounding."""
    months = years * 12
    monthly_rate = (1 + annual_rate_pct / 100 / 2) ** (2 / 12) - 1
    if monthly_rate == 0:
        return principal / months
    return principal * monthly_rate / (1 - (1 + monthly_rate) ** -months)


def evaluate(app: Application, gds_limit: float, tds_limit: float) -> Decision:
    rate = qualifying_rate(app.contract_rate)
    payment = monthly_payment(app.loan_amount, rate, app.amortization_years)
    income = app.annual_income / 12

    housing = (
        payment
        + app.property_tax_annual / 12
        + app.heating_monthly
        + app.condo_fees_monthly * 0.5  # lenders count half of condo fees
    )
    gds = housing / income
    tds = (housing + app.other_debt_monthly) / income

    reasons = []
    if gds > gds_limit:
        reasons.append(f"GDS {gds:.1%} is above the {gds_limit:.0%} limit")
    if tds > tds_limit:
        reasons.append(f"TDS {tds:.1%} is above the {tds_limit:.0%} limit")

    return Decision(
        qualifying_rate=round(rate, 2),
        monthly_payment=round(payment, 2),
        gds_ratio=round(gds, 4),
        tds_ratio=round(tds, 4),
        gds_limit=gds_limit,
        tds_limit=tds_limit,
        approved=not reasons,
        reasons=reasons,
    )
