# Wafer Fab Digital Twin

![R](https://img.shields.io/badge/R-4.x-blue?logo=r)
![tidyverse](https://img.shields.io/badge/tidyverse-2.0%2B-1f78b4)
![License](https://img.shields.io/badge/License-MIT-green)
![Status](https://img.shields.io/badge/Status-Complete-brightgreen)

> **Data-driven digital twin of a semiconductor wafer fab — bottleneck detection, processing-time modeling, and lot-priority simulation**

## Overview

A wafer fab is one of the most complex manufacturing environments in industry: hundreds of machines, multiple production stages, and routes spanning hundreds of operations per product. Small disruptions — a machine breakdown, a congested workshop, a poor priority call — cascade into significant delays.

This project builds a **digital twin** of a simulated wafer fab (4 products, 130 machines, 3 workshops) from one year of production logs (~1.3M process records), to:

- Identify the workshop that structurally limits the fab's throughput
- Model a machine's processing-time distribution and predict it from production context
- Simulate the fab's lot-selection policy and validate it against real occupation levels

## Key Results

| Question | Finding |
|---|---|
| **Bottleneck workshop** | **LITHOGRAPHY** — 99.6% utilization, 136 lots queued on average, lowest theoretical max throughput (0.281 lots/h) |
| **Best processing-time model** | Gamma regression on `RECIPE + PRODUCT`, trained across all machines sharing a recipe — **MAPE 0.862** vs. 1.07 for a constant-only baseline (−19%) |
| **Priority policy simulation** | MLE-fitted priority scores cut the occupation-level error on the slowest product by **65%** (8.27 → 2.89 lots) vs. a uniform-priority baseline |

## Visualizations

**Waiting time by product and workshop** — LITHOGRAPHY dominates per-step waiting time across every product, confirming it as the structural bottleneck.

![Waiting time by product and workshop](assets/waiting_time_by_product_workshop.png)

**Daily workshop occupation (WIP)** — machine-level occupation (solid) stays flat while queue-level occupation (dashed) fluctuates heavily, showing permanent saturation rather than transient congestion.

![Daily WIP occupation by workshop](assets/wip_occupation_daily.png)

**Processing-time distribution** — a Gamma distribution (green) fits the machine's processing times far better than an Exponential (red), motivating the choice of Gamma GLMs for prediction.

![Processing time distribution: Exponential vs Gamma fit](assets/process_time_distribution.png)

## Approach

**1. Exploratory analysis** — cycle time per product, workshop occupation (WIP) via cumulative entry/exit event tracking, machine utilization and breakdown rates, theoretical max throughput per workshop to locate the bottleneck.

**2. Processing-time modeling** — compared Exponential vs. Gamma fits for a single machine's processing times, then benchmarked 8 Gamma GLM specifications (varying predictors and training scope) on a held-out test set:

| Model | Predictors | Training scope | MAPE |
|---|---|---|---|
| 1 | Intercept only | Single machine | 1.07 |
| 3 | `RECIPE` | Single machine | 0.906 |
| 6 | `RECIPE` | All machines sharing recipes | 0.863 |
| **7** | **`RECIPE + PRODUCT`** | **All machines sharing recipes** | **0.862** |
| 8 | `RECIPE + PRODUCT + RECIPE_CONTINUITY` | Single machine | 0.861 |

Recipe is by far the dominant predictor; product adds no signal once recipe is known; pooling training data across machines sharing a recipe improves generalization; a "no-setup-change" flag (`RECIPE_CONTINUITY`) is a significant, physically-sensible predictor.

**3. Priority policy simulation** — modeled lot selection as a score-weighted random choice among waiting lots, estimated per-product priority scores by maximum likelihood on observed selection order, then simulated the machine's behavior event-by-event and validated it against real occupation levels (mean absolute error < 5 lots across all products).

## Repository structure

```
wafer-fab-digital-twin/
├── scripts/
│   ├── 01_exploratory_analysis.R   # Cycle time, WIP, utilization, bottleneck analysis
│   └── 02_machine_modeling.R       # Gamma regression models + priority policy simulation
├── data/
│   └── raw_data.zip                # 6 raw CSV tables (see below)
├── assets/                         # Figures used in this README
├── requirements.txt                # R package list
└── README.md
```

## Data

The `data/raw_data.zip` archive contains six CSV tables describing one year of simulated wafer fab production (lot routing, process timestamps, machine breakdowns — ~150 MB uncompressed). Decompress it into `data/` before running the scripts.

| Table | Content | Rows |
|---|---|---|
| `lot_process_table` | Every operation performed on every lot | 1,755,296 |
| `machine_breakdown_table` | Machine breakdown history | 277,107 |
| `lot_arrival_table` | Lot arrival and due dates | 21,931 |
| `interopt_table` | Machine–recipe compatibility per workshop | 2,658 |
| `product_route_table2` | Manufacturing route per product | 361 |
| `machine_table` | Machine characteristics (workshop, breakdown rate) | 130 |

## Running the scripts

```bash
git clone https://github.com/<your-username>/wafer-fab-digital-twin.git
cd wafer-fab-digital-twin
unzip data/raw_data.zip -d data/
```

In R:
```r
install.packages("tidyverse")
source("scripts/01_exploratory_analysis.R")
source("scripts/02_machine_modeling.R")
```

## Tech stack

| Tool | Use |
|---|---|
| R / tidyverse | Data wrangling, feature engineering |
| ggplot2 | Visualization |
| Gamma GLM (`glm`, `family = Gamma`) | Processing-time prediction |
| Maximum likelihood (`optim`) | Priority-score estimation |
| Discrete-event simulation | Priority policy validation |

## License

MIT — see [LICENSE](LICENSE).