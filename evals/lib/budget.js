'use strict';
// Budget caps and the suite ledger. Caps come from evals/budget.json, never from code.
// Money is rounded to 6 places after every sum so 0.6 + 0.6 compares equal to 1.2.

const fs = require('fs');

const round = n => Math.round(n * 1e6) / 1e6;
const isMoney = v => typeof v === 'number' && Number.isFinite(v) && v > 0;

function loadBudget(file) {
  let b;
  try { b = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) { throw new Error(`cannot read budget ${file}: ${e.message}`); }
  for (const k of ['perEvalUsd', 'perSuiteUsd', 'monthlyCeilingUsd']) {
    if (!isMoney(b[k])) throw new Error(`budget ${file}: ${k} must be a positive number, got ${JSON.stringify(b[k])}`);
  }
  if (b.model !== undefined && typeof b.model !== 'string') throw new Error(`budget ${file}: model must be a string`);
  return b;
}

// Tracks what the suite has spent against the tightest cap in force.
//   measured      sum of costs the runner could read
//   unknownCount  evals whose cost could not be read
// An unreadable cost is budgeted at the per-eval cap (claude was told not to exceed it),
// so it cannot hide spend. That bound is a worst case, never reported as measured.
class Ledger {
  constructor(budget, monthSpent) {
    this.budget = budget;
    this.monthSpent = monthSpent;      // number, or null when the caller did not supply it
    this.measured = 0;
    this.unknownCount = 0;
  }

  get used() { return round(this.measured + this.unknownCount * this.budget.perEvalUsd); }

  // Dollars left under the suite cap, and under the monthly ceiling when its spend is known.
  get suiteRemaining() { return round(this.budget.perSuiteUsd - this.used); }
  get monthRemaining() {
    return this.monthSpent === null ? Infinity : round(this.budget.monthlyCeilingUsd - this.monthSpent - this.used);
  }
  get remaining() { return Math.min(this.suiteRemaining, this.monthRemaining); }
  get binding() { return this.monthRemaining < this.suiteRemaining ? 'monthly' : 'suite'; }

  // Budget to hand to the next eval, or 0 when no eval may start.
  allowance() { return Math.max(0, Math.min(this.budget.perEvalUsd, this.remaining)); }

  record(costUsd) {
    if (costUsd === null) this.unknownCount += 1;
    else this.measured = round(this.measured + costUsd);
  }

  describeStop() {
    const b = this.budget;
    if (this.binding === 'monthly') {
      return `MONTHLY CEILING REACHED: monthly ceiling ${usd(b.monthlyCeilingUsd)}, spent this month ${usd(round(this.monthSpent + this.used))}`;
    }
    return `SUITE CAP REACHED: spent ${usd(this.used)}, cap ${usd(b.perSuiteUsd)}`;
  }
}

function usd(n) { return `$${n.toFixed(4)}`; }

module.exports = { loadBudget, Ledger, usd, round };
