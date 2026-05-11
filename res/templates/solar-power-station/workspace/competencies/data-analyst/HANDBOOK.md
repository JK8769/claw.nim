# Data Analyst

This competency teaches an agent **how to think about data
analysis tasks** — methodology, validation discipline, model
selection, honest reporting. It is **domain-agnostic**: it
doesn't know what plant inverters are, or what clearing prices
mean, or what a clinical trial endpoint is. Pair it with a domain
competency (`solar-operator`, future `market-analyst`,
`clinical-knowledge`, etc.) so you have both *what the data means*
and *what to do with it*.

If you have only this competency loaded, you can reason about
methodology and methods but should defer domain-specific feature
choices, sanity ranges, and terminology to whoever is asking
(or refuse the task if the user expects domain expertise).

---

## The core discipline: hypothesis → method → validation → uncertainty

Before any model or analysis, write down (in your reasoning, or
explicitly in a `reply_progress`):

1. **What's the question?** Phrased as a hypothesis you can test
   or a quantity you can estimate. *"Is plant X under-performing?"*
   has a baseline implied; *"Predict tomorrow's output"* has a
   target and an evaluation horizon.
2. **What method matches the question?** A regression for a
   continuous trend, a classification for a state ("anomaly: yes
   / no"), a tree ensemble for tabular non-linear, a time-series
   model for autoregressive structure. **Don't pick a model
   first, then ask what to do with it.** Pick the question first.
3. **What validation answers "is this real?"** Train/eval/test
   split for predictive work. Out-of-sample test for any claim
   that will be acted on. Backtesting on a held-out window for
   anything time-series. Without this, the analysis is not
   evidence — it's a guess in fancy clothing.
4. **What's the uncertainty?** A point estimate without a
   confidence interval, a model accuracy without a baseline, an
   "Oracle 99%" without explaining what Oracle means in this
   context — these are not finished work. Always report what
   could change the answer.

---

## Model selection by question shape

| Question | Method family | Key validation | Common trap |
|---|---|---|---|
| "Is this anomalous?" | Z-score / IQR / isolation forest | Holdout days with ground-truth labels | Assuming Gaussian when data is heavy-tailed |
| "What will X be tomorrow?" | Time-series regression / GBDT with lagged features | Walk-forward CV | Leakage from future features; not stationarity |
| "Are A and B different?" | Hypothesis test (t / Mann-Whitney / chi-sq) | Effect size + p-value, not p-value alone | p-hacking by trying many tests |
| "Which feature matters most?" | Feature importance from tree model + permutation | Permutation test, not training importance alone | Correlated features split importance |
| "What's the best policy?" | Counterfactual simulation / A-B test | Sensitivity to assumptions | Selection bias on who got which policy |

When the question doesn't fit any of these cleanly, **say so and
ask** — don't force it into the closest available method.

---

## Train / eval / test discipline

For any predictive work:

- **Train set** — used to fit the model. Never used to make claims
  about performance.
- **Eval set** (validation) — used to tune hyperparameters,
  compare models, decide architecture. Not used for the final
  performance claim.
- **Test set** — held out, untouched until the final claim.
  Performance reported here is the only number that gets shared
  with the user.

Time-series adds two more disciplines:
- **Walk-forward**, not random shuffle. Future leaks if you
  shuffle.
- **Hold out the last N days** as test, even if the dataset is
  short. A model evaluated on past days reused as test set is
  pretending.

Common leakage modes to check:
- Target included in features (literal value or transform of it)
- Future features (anything computed using info that wouldn't be
  available at prediction time)
- Group leakage (same plant / same customer in train and test)
- Time leakage (last week leaks into validation if shuffle is used)

---

## Honest performance reporting

**Anti-fabrication is non-negotiable.** This is the rule that
separates a useful analyst from a noise generator.

- Never report a metric you didn't actually compute. If the file
  says "Oracle efficiency 99.40%," and you didn't run the
  evaluation that produced that number, that's prior work — not
  your performance claim.
- Never present prior results as fresh. If the user asks for a
  modeling pass and you find existing artifacts, the existing
  artifacts are *background*, not the deliverable. Confirm with
  the user whether to reuse or refresh.
- Never quote a single number without context. "RMSE = 5.3 kW"
  means nothing without (a) the typical magnitude of the target,
  (b) the baseline error from a trivial model (mean / persistence
  / climatology), (c) the temporal scope of the evaluation.
- "Oracle" / "perfect-information" / "best-case" benchmarks are
  fine to report **with the asterisks**: this is the upper bound
  if a hypothetical perfect predictor existed, not the realised
  performance.

A useful performance report has at minimum:
- Method (one sentence)
- Baseline comparison (what naive approach gives)
- Test-set metric with units
- Confidence interval or uncertainty estimate
- One sentence on what could make this worse in production

---

## When to re-train vs reuse

When a request implies modeling work:

1. **Check what exists.** Look for prior model artifacts in the
   workstation, prior results files, prior evaluation notebooks.
2. **Decide the right path** based on user intent:
   - *"Build a new model for X"* — fresh training, new evaluation,
     new report. Existing artifacts are reference, not deliverable.
   - *"Show me how Y performs"* — existing artifacts are fine,
     just summarise them. **Surface that you're reusing prior
     work** — don't pretend it's fresh.
   - *"Re-evaluate Y on new data"* — reuse the model, run fresh
     evaluation. Halfway between the above.
3. **When intent is ambiguous, ask.** This is exactly the Phase 0
   intake discipline from `technical-communication`. Reusing prior
   work and presenting it as fresh is a high-cost mistake.

---

## Communicating uncertainty

The hardest part of analysis is conveying confidence. A few rules:

- A point estimate should always be paired with a range. *"Output
  tomorrow: 4.2 MWh ±0.8 MWh (90% CI)"*, not just "4.2 MWh."
- If the data is too small for a useful CI, **say so** and report
  the point estimate as a guess, not a forecast. *"With only 5
  days of history, take this as orientation, not prediction."*
- If a baseline beats your model on the test set, that's the
  result — say so. "The seasonal-naive baseline outperformed our
  ensemble" is honest; "Our ensemble achieved 12% MAPE" while
  hiding that the baseline was 9% is misleading.
- Report what the model **does not see**: weather forecasts not
  fed in, regulatory changes that affect the period, equipment
  issues during the window. These are the things that can break
  your forecast in production.

---

## What this competency does NOT cover

- **Domain expertise** — what units mean, what's physically
  reasonable, what's a domain-specific gotcha. Use a domain
  competency (`solar-operator`, etc.). This competency assumes
  you have a domain partner.
- **Output format** — how to structure progress updates, when to
  use cards vs docs, async-tool handoff. Use
  `technical-communication`.
- **Specific tool usage** — how to call fleet adapter tools,
  vendor MCPs, anygen, filesystem. Use the relevant skill.

If a domain competency isn't loaded and the task requires domain
judgment, **don't fake it**. Ask the user, or refuse the task.
A model with a wrong unit assumption is worse than no model.
