# Loss Reserving & Risk Analytics Engine

A loss reserving pipeline for general insurance, combining actuarial methods with a stochastic simulation engine and an interactive Shiny dashboard.

---

## Table of Contents

- [Overview](#overview)
- [Background](#background)
- [Architecture](#architecture)
- [Data Simulation](#data-simulation)
- [SQL Layer](#sql-layer)
- [Reserving Methods](#reserving-methods)
- [Shiny Dashboard](#shiny-dashboard)
- [Setup](#setup)
- [Usage](#usage)
- [Further Work](#further-work)
- [References](#references)

---

## Overview

Loss reserving is the process by which an insurer estimates how much it will ultimately pay on claims that have already occurred but are not yet fully settled. This project builds a full reserving pipeline, from raw claims transactions to interactive reserve estimates with uncertainty quantification.

Rather than using a pre-cleaned triangle, the presented pipeline simulates the entire claims lifecycle from scratch, injecting realistic noise (mixed date formats, zero payments, subrogation), then uses a SQL layer to clean and construct the development triangle, and finally applies two industry-standard reserving methods with an interactive dashboard for exploring results.

---

## Background

### Loss Triangle

The fundamental data structure in loss reserving is the **development triangle** : a matrix where rows represent accident years and columns represent development years. Each cell contains the cumulative paid losses for claims from that accident year as of that development period.

```
           Dev Year 1   Dev Year 2   Dev Year 3   ...   Dev Year 10
AY 2016       X            X            X          ...       X
AY 2017       X            X            X          ...       ?
AY 2018       X            X            X          ...       ?
...
AY 2025       X            ?            ?          ...       ?
```

The lower-right triangle is unobserved => these are the future payments the insurer must reserve for. Ultimately, The goal of loss reserving is to estimate these missing cells and sum them to produce an **IBNR** (Incurred But Not Reported) reserve estimate.

### Why This Matters?

Reserving errors have real consequences, under-reserving leads to insolvency risk, over-reserving leads to misallocation of capital. Regulatory frameworks (Solvency II in Europe, for example) require insurers to hold reserves at specific confidence levels, making uncertainty quantification essential.

---

## Architecture

```
01_stoch_data_generator.R
  Simulate claims lifecycle → raw_claims_transactions.csv
          ↓
02_sql_engine.R
  DuckDB ingestion + cleaning + triangle construction
  → insurance_reserving.duckdb (v_incremental_triangle view)
          ↓
global.R
  Load triangle from DB → cumulative triangle matrix
          ↓
app.R
  Shiny dashboard
  ├── Mack Chain Ladder (deterministic point estimate)
  └── ODP Bootstrap (stochastic)
```

---

## Data Simulation

Rather than using a pre-cleaned benchmark dataset, `01_stoch_data_generator.R` simulates the full claims lifecycle with actuarially motivated distributions.

### Claim Counts

Annual claim counts follow a **Poisson distribution** with a growing portfolio:

```math
N_t \sim \text{Poisson}(\lambda \cdot g^t), \quad \lambda = 1500, \quad g = 1.05
```

A 5% annual growth rate reflects a typical expanding general insurance portfolio.

### Claim Severity

Ultimate claim costs follow a **Log-Normal distribution** adjusted for inflation:

```math
U_i \sim \text{LogNormal}(\mu = 8.5,\ \sigma = 1.5) \times (1.04)^{t - t_0}
```

Log-Normal is the standard actuarial choice for severity — it captures the right-skewed distribution of insurance losses where large claims are rare but extremely costly.

### Reporting Delay

Reporting delays follow a **Weibull distribution**:

```math
D_i \sim \text{Weibull}(\text{shape} = 1.2,\ \text{scale} = 30)
```

The Weibull shape > 1 produces a distribution where most claims are reported quickly but a long right tail captures late-reported claims — consistent with empirical patterns in general insurance.

### Incremental Payments

Each claim is split into 1–5 incremental payments with exponentially distributed inter-payment delays (~90 days). Payment proportions are sampled from a Dirichlet-like process (normalized uniform draws).

### Injected Noise

To simulate real-world data quality issues:

- **5% zero payments** — claims closed without payment
- **2% negative payments** — subrogation recoveries
- **20% date format inconsistency** — transaction dates randomly formatted as `DD/MM/YYYY` instead of `YYYY-MM-DD`, simulating manual data entry errors

---

## SQL Layer

`02_sql_engine.R` uses **DuckDB** to ingest the raw CSV and construct the development triangle via a SQL view.

### Date Cleaning

The mixed date formats injected during simulation are handled with a `COALESCE + TRY_CAST` pattern:

```sql
COALESCE(
    TRY_CAST(transaction_date AS DATE),
    strptime(transaction_date, '%d/%m/%Y')::DATE
) AS transaction_date
```

This attempts ISO format first and falls back to `DD/MM/YYYY` parsing.

### Triangle Construction

Development year is computed as the difference between transaction year and accident year:

```sql
EXTRACT(YEAR FROM transaction_date) 
    - EXTRACT(YEAR FROM accident_date) + 1 AS dev_year
```

Incremental paid amounts are then aggregated by accident year and development year to produce the triangle view `v_incremental_triangle`.

### Why DuckDB?

DuckDB is an embedded analytical database, so no server required, runs in-process, reads CSVs natively, and supports full SQL.

---

## Reserving Methods

### 1. Mack Chain Ladder

The chain ladder method projects each accident year's cumulative losses to ultimate using **age-to-age development factors** estimated from the observed triangle:

```math
f_k = \frac{\sum_{i} C_{i,k+1}}{\sum_{i} C_{i,k}}
```

where $C_{i,k}$ is cumulative paid losses for accident year $i$ at development year $k$.

The **Mack (1993)** extension adds a distribution-free estimate of the prediction error, quantifying the uncertainty around each reserve estimate without parametric assumptions.

**Output:** Point estimate of IBNR by accident year with standard errors.

### 2. Overdispersed Poisson Bootstrap 

The **ODP Bootstrap** (England & Verrall, 1999) fits a GLM with an Overdispersed Poisson family to the incremental triangle, then:

1. Computes Pearson residuals from the fitted GLM
2. Resamples residuals with replacement to generate pseudo-triangles
3. Re-fits the GLM and projects to ultimate for each pseudo-triangle
4. Repeats 10,000 times to build an empirical distribution of IBNR

This produces a full predictive distribution of reserve outcomes, enabling VaR-style risk quantification:

```math
\text{VaR}_{95\%} = Q_{0.95}(\text{IBNR}_{1}, \ldots, \text{IBNR}_{10000})
```

**Output:** Full IBNR distribution with 75th and 95th percentile risk buffers by accident year.

---

## Shiny Dashboard

The dashboard (`app.R` + `global.R`) provides an interactive interface for exploring reserve estimates.

**Key features:**

- Toggle between Mack Chain Ladder and ODP Bootstrap
- Adjust number of bootstrap iterations (1,000–50,000)
- Value boxes showing estimated ultimate loss, total IBNR, and 95th percentile VaR
- Stacked bar chart with risk buffers (mean IBNR / 75th / 95th percentile) by accident year
- Completed development triangle (squared triangle) with color-coded observed vs projected cells

---

## Setup

### Requirements

- R ≥ 4.2
- RStudio (recommended)

### Install packages

```r
install.packages(c(
  "shiny", "bslib", "bsicons",
  "ChainLadder", "dplyr", "tidyr",
  "plotly", "DT", "DBI", "duckdb",
  "lubridate", "purrr"
))
```

### Run the pipeline

**Step 1 — Simulate claims data:**
```r
source("01_stoch_data_generator.R")
# Generates raw_claims_transactions.csv (~37,000 transactions)
```

**Step 2 — Build the database and triangle:**
```r
source("02_sql_engine.R")
# Creates insurance_reserving.duckdb with v_incremental_triangle view
```

**Step 3 — Launch the Shiny dashboard:**
```r
shiny::runApp(".")
# Or open app.R in RStudio and click Run App
```

---

## Project Structure

```
loss-reserving/
├── 01_stoch_data_generator.R   # Claims lifecycle simulation
├── 02_sql_engine.R             # DuckDB ingestion + triangle construction
├── global.R                    # Data loading + triangle formatting for Shiny
├── app.R                       # Shiny UI + server
├── raw_claims_transactions.csv # Generated claims data (~37k rows)
└── insurance_reserving.duckdb  # DuckDB database (auto-generated)
```

---

## Further Work

**Tail factor adjustment**: the current pipeline uses the development factors implied by the triangle without explicit tail selection. Adding a user-controlled tail factor in the Shiny sidebar would allow sensitivity analysis beyond the last observed development year.

**Multiple lines of business**: the current simulation generates a single homogeneous portfolio. Extending to multiple lines (e.g. motor, liability, property) with different severity and development patterns would better reflect a real insurer's reserving challenge.

**Solvency II SCR calculation**: the 95th percentile VaR from the bootstrap is directly analogous to the Solvency Capital Requirement under Solvency II. Adding an explicit SCR calculation and comparing it to the standard formula for European insurance regulatory contexts.

---

## References

1. Mack, T. (1993). *Distribution-free calculation of the standard error of chain ladder reserve estimates.* ASTIN Bulletin.
2. England, P. & Verrall, R. (1999). *Analytic and bootstrap estimates of prediction errors in claims reserving.* Insurance: Mathematics and Economics.
3. Venter, G. (1998). *Testing the assumptions of age-to-age factors.* CAS Proceedings.
4. ChainLadder R package: Gesmann et al. [CRAN](https://cran.r-project.org/package=ChainLadder)
5. DuckDB: [duckdb.org](https://duckdb.org)
