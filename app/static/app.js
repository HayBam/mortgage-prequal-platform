// Broker portal: sends the form to POST /v1/prequalify and shows the decision.
// The API key lives only in the password field. It is not saved to storage,
// cookies or logs, and it goes to the server in the X-API-Key header only.
"use strict";

const EXAMPLES = {
  // Comfortably inside both limits.
  strong: { annual_income: 150000, loan_amount: 450000, contract_rate: 4.5, property_tax_annual: 4800, other_debt_monthly: 300 },
  // TDS about 43.2%: approved at the 44% limit, declined if Git lowers TDS_LIMIT to 0.42.
  borderline: { annual_income: 125000, loan_amount: 500000, contract_rate: 4.5, property_tax_annual: 4800, other_debt_monthly: 650 },
  // Too much other debt: declined on TDS.
  "high-debt": { annual_income: 90000, loan_amount: 500000, contract_rate: 4.5, property_tax_annual: 4000, other_debt_monthly: 1500 },
};
const DEFAULTS = { amortization_years: 25, heating_monthly: 100, condo_fees_monthly: 0, property_tax_annual: 0, other_debt_monthly: 0 };
const NUMERIC = ["annual_income", "loan_amount", "contract_rate", "amortization_years",
  "property_tax_annual", "heating_monthly", "condo_fees_monthly", "other_debt_monthly"];
const REQUIRED = ["annual_income", "loan_amount", "contract_rate"];
const METER_MAX = 0.6; // meters show 0-60%

const $ = (id) => document.getElementById(id);
const money = new Intl.NumberFormat("en-CA", { style: "currency", currency: "CAD" });
const pct = (x, digits = 1) => (x * 100).toFixed(digits) + "%";

function labelFor(name) {
  const label = document.querySelector(`label[for="${name}"]`);
  return label ? label.textContent : name;
}

function showError(message, fields = []) {
  const box = $("form-error");
  box.textContent = message;
  box.hidden = false;
  fields.forEach((f) => $(f) && $(f).setAttribute("aria-invalid", "true"));
}

function clearError() {
  $("form-error").hidden = true;
  document.querySelectorAll("[aria-invalid]").forEach((el) => el.removeAttribute("aria-invalid"));
}

function loadExample(name) {
  const values = { ...DEFAULTS, ...EXAMPLES[name] };
  Object.entries(values).forEach(([k, v]) => { if ($(k)) $(k).value = v; });
  clearError();
  $("api_key").value ? $("submit").focus() : $("api_key").focus();
}

function readForm() {
  const body = {};
  const missing = REQUIRED.filter((k) => $(k).value.trim() === "");
  NUMERIC.forEach((k) => { if ($(k).value.trim() !== "") body[k] = Number($(k).value); });
  return { body, missing };
}

function setMeter(id, ratio, limit) {
  const meter = $(id);
  const over = ratio > limit;
  meter.classList.toggle("is-over", over);
  meter.querySelector(".meter-val").textContent = pct(ratio);
  meter.querySelector(".meter-fill").style.width = Math.min(ratio / METER_MAX, 1) * 100 + "%";
  meter.querySelector(".meter-limit").style.left = Math.min(limit / METER_MAX, 1) * 100 + "%";
  meter.querySelector(".meter-foot").textContent = over
    ? `Above the ${pct(limit, 0)} limit by ${pct(ratio - limit)}`
    : `Within the ${pct(limit, 0)} limit (${pct(limit - ratio)} headroom)`;
}

function showDecision(d) {
  $("result-empty").hidden = true;
  $("result").hidden = false;

  const verdict = $("verdict");
  verdict.classList.toggle("is-approved", d.approved);
  verdict.classList.toggle("is-declined", !d.approved);
  $("verdict-title").textContent = d.approved ? "Pre-qualified" : "Not pre-qualified";
  $("verdict-sub").textContent = d.approved
    ? "The client passes the stress test within both debt-service limits."
    : "The client does not meet the debt-service limits at the qualifying rate.";

  $("qualifying_rate").textContent = d.qualifying_rate.toFixed(2) + "%";
  $("monthly_payment").textContent = money.format(d.monthly_payment);
  setMeter("meter-gds", d.gds_ratio, d.gds_limit);
  setMeter("meter-tds", d.tds_ratio, d.tds_limit);

  const reasons = $("reasons");
  reasons.replaceChildren(...d.reasons.map((r) => Object.assign(document.createElement("li"), { textContent: r })));

  $("request_id").textContent = d.request_id;
  $("policy").textContent = `Policy in force: GDS up to ${pct(d.gds_limit, 0)}, TDS up to ${pct(d.tds_limit, 0)}. ` +
    "The limits are set in Git and deployed by Argo CD.";

  // On narrow screens the decision sits below the form: bring it into view.
  if (window.matchMedia("(max-width: 59.99rem)").matches) {
    const smooth = !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    $("result-title").scrollIntoView({ behavior: smooth ? "smooth" : "auto", block: "start" });
  }
}

async function submit(event) {
  event.preventDefault();
  clearError();

  const key = $("api_key").value.trim();
  const { body, missing } = readForm();
  if (!key) return showError("Enter the broker API key.", ["api_key"]);
  if (missing.length) return showError("Fill in: " + missing.map(labelFor).join(", ") + ".", missing);

  const button = $("submit");
  button.disabled = true;
  button.textContent = "Checking…";
  try {
    const res = await fetch("/v1/prequalify", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": key },
      body: JSON.stringify(body),
      cache: "no-store",
    });
    const data = await res.json().catch(() => ({}));
    if (res.ok) return showDecision(data);
    if (res.status === 401) return showError("The broker API key was not accepted.", ["api_key"]);
    if (res.status === 422 && Array.isArray(data.detail)) {
      const fields = data.detail.map((e) => e.loc && e.loc[e.loc.length - 1]).filter(Boolean);
      return showError("Check these values: " + [...new Set(fields)].map(labelFor).join(", ") + ".", fields);
    }
    showError(`The service returned an error (HTTP ${res.status}). Try again.`);
  } catch {
    showError("The service could not be reached. Check that the port-forward is still running.");
  } finally {
    button.disabled = false;
    button.textContent = "Check pre-qualification";
  }
}

async function loadStatus() {
  try {
    const v = await (await fetch("/version", { cache: "no-store" })).json();
    $("version").textContent = String(v.version).slice(0, 12);
  } catch { $("version").textContent = "unknown"; }

  const status = $("status");
  try {
    const ready = (await fetch("/readyz", { cache: "no-store" })).ok;
    status.classList.add(ready ? "is-ready" : "is-down");
    $("status-text").textContent = ready ? "Service ready" : "Key not loaded";
  } catch {
    status.classList.add("is-down");
    $("status-text").textContent = "Service unreachable";
  }
}

document.addEventListener("DOMContentLoaded", () => {
  $("prequal-form").addEventListener("submit", submit);
  $("prequal-form").addEventListener("reset", () => {
    clearError();
    $("result").hidden = true;
    $("result-empty").hidden = false;
  });
  document.querySelectorAll("[data-example]").forEach((b) =>
    b.addEventListener("click", () => loadExample(b.dataset.example)));
  $("copy-ref").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText($("request_id").textContent);
      $("copy-ref").textContent = "Copied";
      setTimeout(() => { $("copy-ref").textContent = "Copy"; }, 1500);
    } catch { /* clipboard blocked: the ID is still visible to select */ }
  });
  loadStatus();
});
