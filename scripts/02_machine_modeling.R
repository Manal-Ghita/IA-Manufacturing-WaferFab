# ==============================================================================
# Wafer Fab Digital Twin — Machine-Level Modeling
#
# Builds a data-driven digital twin of a single machine (MACHINE_0008,
# workshop LITHOGRAPHY): models its processing-time distribution with a
# Gamma GLM, compares eight candidate specifications, then fits and
# validates a score-based lot-selection (priority) policy by maximum
# likelihood, simulated against real occupation levels.
#
# Input : six raw CSV tables in data/ (see data/README.md for schema)
# Output: model summaries, MAE/MAPE comparison table, and a process-time
#         distribution plot saved to plots/
# ==============================================================================

library(tidyverse)

dir.create("plots", showWarnings = FALSE)

# ------------------------------------------------------------------------------
# 0. Load raw data and build the lot-level dataframe
# ------------------------------------------------------------------------------
# Note: filtered on a narrower period (2024-01-01 to 2024-07-01) than the EDA
# script, since this analysis needs a clean train/test split around
# 2024-04-01 rather than the full exploratory study period.

product_route_df <- read_csv2("data/product_route_table2.csv")

lot_process_df <- read_csv2(file = "data/lot_process_table.csv") %>%
  mutate(PROCESS_BEGIN_DATE = as_datetime(PROCESS_BEGIN_DATE / 1000.),
         PROCESS_END_DATE = as_datetime(PROCESS_END_DATE / 1000.))

lot_arrival_df <- read_csv2(file = "data/lot_arrival_table.csv") %>%
  mutate(ARRIVAL_DATE = as_datetime(ARRIVAL_DATE / 1000.),
         DUE_DATE = as_datetime(DUE_DATE / 1000.))

machine_table <- read_csv2(file = "data/machine_table.csv")

machine_breakdown_df <- read_csv2(file = "data/machine_breakdown_table.csv") %>%
  mutate(BREAKDOWN_BEGIN_DATE = as_datetime(BREAKDOWN_BEGIN_DATE / 1000.),
         BREAKDOWN_END_DATE = as_datetime(BREAKDOWN_END_DATE / 1000.))

# Merge process, routing (adds WORKSHOP, RECIPE) and arrival info, then
# derive WORKSHOP_BEGIN_DATE the same way as in the EDA script.
lot_detailed_df <- lot_process_df %>%
  left_join(product_route_df) %>%
  left_join(lot_arrival_df) %>%
  select(LOT, PRODUCT, RECIPE, OPERATION, WORKSHOP, MACHINE,
         PROCESS_BEGIN_DATE, PROCESS_END_DATE, ARRIVAL_DATE) %>%
  arrange(LOT, PROCESS_BEGIN_DATE) %>%
  group_by(LOT) %>%
  mutate(
    WORKSHOP_BEGIN_DATE = lag(PROCESS_END_DATE),
    WORKSHOP_BEGIN_DATE = ifelse(
      is.na(lag(PROCESS_END_DATE)),
      as.double(ARRIVAL_DATE),
      as.double(WORKSHOP_BEGIN_DATE)
    ),
    WORKSHOP_BEGIN_DATE = as_datetime(WORKSHOP_BEGIN_DATE)
  ) %>%
  ungroup() %>%
  filter(WORKSHOP_BEGIN_DATE <= as_datetime("2024-07-01") &
           PROCESS_END_DATE >= as_datetime("2024-01-01")) %>%
  mutate(
    S    = as.double(PROCESS_END_DATE - PROCESS_BEGIN_DATE) / 60 + 0.000001, # processing time (min); tiny offset avoids zeros for Gamma fitting
    TEST = PROCESS_END_DATE >= as_datetime("2024-04-01")                     # TRUE = test set (after 2024-04-01)
  )

# lot_detailed_df columns:
#  LOT                 lot label
#  PRODUCT             product label of the lot
#  RECIPE              recipe label of the current operation
#  OPERATION           operation label of the current process step
#  WORKSHOP            workshop label of the current process step
#  MACHINE             machine chosen for this process step
#  PROCESS_BEGIN_DATE  datetime the lot enters MACHINE
#  PROCESS_END_DATE    datetime the lot exits MACHINE
#  ARRIVAL_DATE        datetime the lot first arrived in the fab
#  WORKSHOP_BEGIN_DATE datetime the lot enters WORKSHOP and starts queuing
#                      (equals PROCESS_BEGIN_DATE if there is no queuing)
#  S                   processing time on the machine, in minutes
#  TEST                TRUE if PROCESS_END_DATE is after 2024-04-01 (test set)

# ------------------------------------------------------------------------------
# 1. Processing-time distribution — Exponential vs. Gamma fit
# ------------------------------------------------------------------------------

selected_machine <- "MACHINE_0008"

model_data <- lot_detailed_df %>%
  filter(MACHINE == selected_machine)

model_data_training <- model_data %>%
  filter(!TEST)  # data before 2024-04-01

model_data_test <- model_data %>%
  filter(TEST)   # data after 2024-04-01

# Method-of-moments Gamma parameters
scale <- var(model_data$S) / mean(model_data$S)
shape <- mean(model_data$S) / scale

# Bin size for the empirical vs. theoretical distribution plot
bin_size <- 10

p_dist <- model_data %>%
  select(S) %>%
  mutate(S_ceiling = ceiling(S / bin_size) * bin_size) %>%
  group_by(S_ceiling) %>%
  summarize(n = n()) %>%
  ungroup() %>%
  mutate(
    prop           = n / sum(n),                                     # observed proportion per bin
    prop_th_exp    = pexp(S_ceiling, rate = 1 / mean(model_data$S)),  # Exponential CDF
    prop_th_exp    = prop_th_exp - ifelse(                            # Exponential PDF per bin
      is.na(lag(prop_th_exp)), 0, lag(prop_th_exp)),
    prop_th_gamma  = pgamma(S_ceiling, shape = shape, scale = scale), # Gamma CDF
    prop_th_gamma  = prop_th_gamma - ifelse(                          # Gamma PDF per bin
      is.na(lag(prop_th_gamma)), 0, lag(prop_th_gamma))
  ) %>%
  ggplot(aes(S_ceiling, prop)) +
  geom_col() +
  geom_line(aes(y = prop_th_exp),   color = "red") +
  geom_line(aes(y = prop_th_gamma), color = "green") +
  geom_vline(aes(xintercept = mean(model_data$S)), color = "blue") +
  labs(title = str_c("Processing time distribution — ", selected_machine),
       subtitle = "Red: Exponential fit · Green: Gamma fit · Blue: empirical mean",
       x = "Process time (minutes)",
       y = "Proportion")

ggsave("plots/process_time_distribution.png", plot = p_dist, width = 10, height = 6, dpi = 300)

# ------------------------------------------------------------------------------
# 2. Gamma regression models — comparing predictors of processing time
# ------------------------------------------------------------------------------
# Models 1-4 train on MACHINE_0008 only. Models 5-7 train on all machines
# sharing the same recipes (model_data_training_alt), giving a much larger
# training set. Model 8 adds RECIPE_CONTINUITY (no setup change vs. previous
# operation on the same machine).

model_gamma1 <- glm(S ~ 1, data = model_data_training,
                    family = Gamma(link = "log"))
summary(model_gamma1)

model_gamma2 <- glm(S ~ PRODUCT, data = model_data_training,
                    family = Gamma(link = "log"))
summary(model_gamma2)

model_gamma3 <- glm(S ~ RECIPE, data = model_data_training,
                    family = Gamma(link = "log"))
summary(model_gamma3)

model_gamma4 <- glm(S ~ RECIPE + PRODUCT, data = model_data_training,
                    family = Gamma(link = "log"))
summary(model_gamma4)

model_data_training_alt <- lot_detailed_df %>%
  filter(!TEST & RECIPE %in% unique(model_data_training$RECIPE)) %>%
  filter(S > 0)

model_gamma5 <- glm(S ~ 1, data = model_data_training_alt,
                    family = Gamma(link = "log"))
summary(model_gamma5)

model_gamma6 <- glm(S ~ RECIPE, data = model_data_training_alt,
                    family = Gamma(link = "log"))
summary(model_gamma6)

model_gamma7 <- glm(S ~ RECIPE + PRODUCT, data = model_data_training_alt,
                    family = Gamma(link = "log"))
summary(model_gamma7)

# RECIPE_CONTINUITY: TRUE if the recipe matches the previous operation on the
# same machine (i.e. no setup/configuration change)
# W: total time spent in the workshop (queuing + processing), in minutes —
# used later as a simple heuristic proxy for the priority scores
model_data <- model_data %>%
  arrange(MACHINE, PROCESS_BEGIN_DATE) %>%
  mutate(
    RECIPE_CONTINUITY = RECIPE == lag(RECIPE),
    RECIPE_CONTINUITY = ifelse(is.na(RECIPE_CONTINUITY), FALSE, RECIPE_CONTINUITY),
    W = as.double(PROCESS_END_DATE - WORKSHOP_BEGIN_DATE) / 60
  )

model_data_training <- model_data %>%
  filter(!TEST)

model_data_test <- model_data %>%
  filter(TEST)

model_gamma8 <- glm(S ~ RECIPE + PRODUCT + RECIPE_CONTINUITY,
                    data = model_data_training,
                    family = Gamma(link = "log"))
summary(model_gamma8)

# Predictions and MAE / MAPE on the test set, for all eight models
model_comparison <- model_data_test %>%
  mutate(
    S_th1 = exp(predict(model_gamma1, newdata = model_data_test)),
    S_th2 = exp(predict(model_gamma2, newdata = model_data_test)),
    S_th3 = exp(predict(model_gamma3, newdata = model_data_test)),
    S_th4 = exp(predict(model_gamma4, newdata = model_data_test)),
    S_th5 = exp(predict(model_gamma5, newdata = model_data_test)),
    S_th6 = exp(predict(model_gamma6, newdata = model_data_test)),
    S_th7 = exp(predict(model_gamma7, newdata = model_data_test)),
    S_th8 = exp(predict(model_gamma8, newdata = model_data_test))
  ) %>%
  select(S, S_th1:S_th8) %>%
  gather(key = model, value = S_pred, S_th1:S_th8) %>%
  group_by(model) %>%
  summarize(
    MAE  = mean(abs(S - S_pred)),
    MAPE = mean(abs(S - S_pred) / S)
  )

print(model_comparison)

# ------------------------------------------------------------------------------
# 3. Priority policy modeling — score-based lot selection
# ------------------------------------------------------------------------------
# When a machine frees up, it must choose which waiting lot to process next.
# We model P(select product i) = (l_i * s_i) / sum_j(l_j * s_j), where l_i is
# the number of waiting lots of product i and s_i its priority score
# (s_PRODUCT_0001 = 1 as reference). Scores are estimated by maximizing the
# log-likelihood of the observed selection order in the training data.

model_data_training2 <- model_data_training %>%
  select(PRODUCT, ARRIVAL_DATE, PROCESS_END_DATE) %>%
  gather(key = "TYPE", value = "DATE", ARRIVAL_DATE, PROCESS_END_DATE) %>%
  mutate(focus = list(unique(model_data_training$PRODUCT))) %>%
  unnest(focus) %>%
  arrange(focus, DATE, TYPE) %>%
  group_by(focus) %>%
  mutate(l = cumsum(focus == PRODUCT & TYPE == "ARRIVAL_DATE") -
           cumsum(focus == PRODUCT & TYPE == "PROCESS_END_DATE"),
         focus = str_c("l_", focus),
         line = seq_along(focus)) %>%
  ungroup() %>%
  arrange(DATE, TYPE) %>%
  spread(key = focus, value = l) %>%
  arrange(DATE, TYPE) %>%
  mutate(l1 = lag(l_PRODUCT_0001),
         l2 = lag(l_PRODUCT_0002),
         l3 = lag(l_PRODUCT_0003),
         l4 = lag(l_PRODUCT_0004)) %>%
  filter(TYPE == "PROCESS_END_DATE") %>%
  select(PRODUCT, DATE, l1, l2, l3, l4)

# Negative log-likelihood of observed selections, given priority scores
# (s2, s3, s4) — s1 is fixed to 1 as the reference product
compute_mLLH <- function(scores) {
  return((model_data_training2 %>%
    mutate(s1 = 1, s2 = scores[[1]], s3 = scores[[2]], s4 = scores[[3]],
           p1 = l1 * s1 / (l1 * s1 + l2 * s2 + l3 * s3 + l4 * s4),
           p2 = l2 * s2 / (l1 * s1 + l2 * s2 + l3 * s3 + l4 * s4),
           p3 = l3 * s3 / (l1 * s1 + l2 * s2 + l3 * s3 + l4 * s4),
           p4 = l4 * s4 / (l1 * s1 + l2 * s2 + l3 * s3 + l4 * s4),
           llh = (PRODUCT == "PRODUCT_0001") * log(p1) +
             (PRODUCT == "PRODUCT_0002") * log(p2) +
             (PRODUCT == "PRODUCT_0003") * log(p3) +
             (PRODUCT == "PRODUCT_0004") * log(p4)) %>%
    summarize(mLLH = -sum(llh, na.rm = TRUE)))$mLLH[[1]])
}

# Baseline: uniform scores (s2 = s3 = s4 = 1)
compute_mLLH(c(1, 1, 1))

# Maximum-likelihood estimation of the priority scores
optimal_scores <- optim(c(1, 1, 1), compute_mLLH)
print(optimal_scores$par)   # ~ 0.4255 (PRODUCT_0002), 0.8270 (PRODUCT_0003), 0.7799 (PRODUCT_0004)
print(optimal_scores$value) # negative log-likelihood at the optimum

# Heuristic score for comparison: ratio of mean cycle times (W1 / Wi)
model_data_training %>%
  group_by(PRODUCT) %>%
  summarize(W = mean(W), .groups = "drop") %>%
  mutate(s_heuristic = W[PRODUCT == "PRODUCT_0001"] / W)

# ------------------------------------------------------------------------------
# 4. Priority policy simulation and validation on the test set
# ------------------------------------------------------------------------------
# Simulates the machine's lot-selection behavior event by event using the
# fitted priority scores, and compares simulated occupation levels (l1..l4)
# against the real observed levels (l1_real..l4_real).

event_df <- model_data_test %>%
  select(PRODUCT, ARRIVAL_DATE, PROCESS_END_DATE) %>%
  gather(key = "TYPE", value = "DATE", ARRIVAL_DATE, PROCESS_END_DATE) %>%
  filter(DATE < as_datetime("2024-07-01")) %>%
  arrange(DATE) %>%
  mutate(
    l1 = 0, l1_real = cumsum(PRODUCT == "PRODUCT_0001" & TYPE == "ARRIVAL_DATE") -
      cumsum(PRODUCT == "PRODUCT_0001" & TYPE == "PROCESS_END_DATE"),
    l2 = 0, l2_real = cumsum(PRODUCT == "PRODUCT_0002" & TYPE == "ARRIVAL_DATE") -
      cumsum(PRODUCT == "PRODUCT_0002" & TYPE == "PROCESS_END_DATE"),
    l3 = 0, l3_real = cumsum(PRODUCT == "PRODUCT_0003" & TYPE == "ARRIVAL_DATE") -
      cumsum(PRODUCT == "PRODUCT_0003" & TYPE == "PROCESS_END_DATE"),
    l4 = 0, l4_real = cumsum(PRODUCT == "PRODUCT_0004" & TYPE == "ARRIVAL_DATE") -
      cumsum(PRODUCT == "PRODUCT_0004" & TYPE == "PROCESS_END_DATE"),
    PRODUCT = ifelse(TYPE == "ARRIVAL_DATE", NA, PRODUCT)
  )

# Use the maximum-likelihood scores estimated above
scores <- c(1, optimal_scores$par[[1]], optimal_scores$par[[2]], optimal_scores$par[[3]])
s1 <- scores[[1]]; s2 <- scores[[2]]; s3 <- scores[[3]]; s4 <- scores[[4]]

for (row in 1:(length(event_df$PRODUCT) - 1)) {
  if (row %% 100 == 0) cat(row, fill = TRUE)

  # Carry forward occupation levels to the next row
  event_df$l1[[row + 1]] <- event_df$l1[[row]]
  event_df$l2[[row + 1]] <- event_df$l2[[row]]
  event_df$l3[[row + 1]] <- event_df$l3[[row]]
  event_df$l4[[row + 1]] <- event_df$l4[[row]]

  if (event_df$TYPE[[row]] == "ARRIVAL_DATE") {
    # A lot arrives: increment the occupation level of the corresponding product
    if (event_df$l1_real[[row]] > ifelse(row == 1, 0, event_df$l1_real[[row - 1]])) {
      event_df$l1[[row + 1]] <- event_df$l1[[row]] + 1
    } else if (event_df$l2_real[[row]] > ifelse(row == 1, 0, event_df$l2_real[[row - 1]])) {
      event_df$l2[[row + 1]] <- event_df$l2[[row]] + 1
    } else if (event_df$l3_real[[row]] > ifelse(row == 1, 0, event_df$l3_real[[row - 1]])) {
      event_df$l3[[row + 1]] <- event_df$l3[[row]] + 1
    } else {
      event_df$l4[[row + 1]] <- event_df$l4[[row]] + 1
    }

  } else { # PROCESS_END_DATE: a machine frees up and selects the next lot

    l1 <- event_df$l1[[row]]; l2 <- event_df$l2[[row]]
    l3 <- event_df$l3[[row]]; l4 <- event_df$l4[[row]]

    p_total <- l1 * s1 + l2 * s2 + l3 * s3 + l4 * s4

    if (p_total > 0) {
      p1 <- l1 * s1 / p_total
      p2 <- l2 * s2 / p_total
      p3 <- l3 * s3 / p_total
      p4 <- l4 * s4 / p_total
    }

    dice <- runif(1)

    if (dice < p1) {
      event_df$PRODUCT[[row]] <- "PRODUCT_0001"
      event_df$l1[[row + 1]] <- event_df$l1[[row]] - 1
    } else if (dice < p1 + p2) {
      event_df$PRODUCT[[row]] <- "PRODUCT_0002"
      event_df$l2[[row + 1]] <- event_df$l2[[row]] - 1
    } else if (dice < p1 + p2 + p3) {
      event_df$PRODUCT[[row]] <- "PRODUCT_0003"
      event_df$l3[[row + 1]] <- event_df$l3[[row]] - 1
    } else {
      event_df$PRODUCT[[row]] <- "PRODUCT_0004"
      event_df$l4[[row + 1]] <- event_df$l4[[row]] - 1
    }
  }
}

# Mean simulated vs. real occupation levels per product
simulation_means <- event_df %>%
  filter(TYPE == "PROCESS_END_DATE") %>%
  summarize(l1_sim = mean(l1), l1_real = mean(l1_real),
            l2_sim = mean(l2), l2_real = mean(l2_real),
            l3_sim = mean(l3), l3_real = mean(l3_real),
            l4_sim = mean(l4), l4_real = mean(l4_real))

print(simulation_means)

# Mean absolute error between simulated and real occupation levels
simulation_mae <- event_df %>%
  filter(TYPE == "PROCESS_END_DATE") %>%
  summarize(MAE_l1 = mean(abs(l1 - l1_real)),
            MAE_l2 = mean(abs(l2 - l2_real)),
            MAE_l3 = mean(abs(l3 - l3_real)),
            MAE_l4 = mean(abs(l4 - l4_real)))

print(simulation_mae)

# Reference results (see report):
#   uniform scores (1,1,1,1):                    MAE = 4.83, 8.27, 5.13, 2.37
#   MLE scores (1, 0.4255, 0.8270, 0.7799):       MAE = 4.92, 2.32, 5.24, 2.81
# The MLE-fitted scores cut the error on PRODUCT_0002 by ~65% (8.27 -> 2.32),
# at the cost of a small increase on the other products.
