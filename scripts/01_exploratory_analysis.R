# ==============================================================================
# Wafer Fab Digital Twin — Exploratory Data Analysis
#
# Analyzes production data from a semiconductor wafer fab (4 products,
# 130 machines across 3 workshops: ETCHING, LITHOGRAPHY, IMPLEMENTATION)
# to characterize cycle times, workshop congestion (WIP), and machine
# utilization / breakdown rates, in order to identify the fab's
# production bottleneck.
#
# Input : six raw CSV tables in data/ (see data/README.md for schema)
# Output: summary tables printed to console + two plots saved to plots/
# ==============================================================================

library(tidyverse)

dir.create("plots", showWarnings = FALSE)

# ------------------------------------------------------------------------------
# 1. Load raw data and build the central lot-level dataframe
# ------------------------------------------------------------------------------

product_route_df <- read_csv2("data/product_route_table2.csv")

lot_process_df <- read_csv2(file = "data/lot_process_table.csv") %>%
  mutate(PROCESS_BEGIN_DATE = as_datetime(PROCESS_BEGIN_DATE / 1000.),
         PROCESS_END_DATE   = as_datetime(PROCESS_END_DATE   / 1000.))

lot_arrival_df <- read_csv2(file = "data/lot_arrival_table.csv") %>%
  mutate(ARRIVAL_DATE = as_datetime(ARRIVAL_DATE / 1000.),
         DUE_DATE     = as_datetime(DUE_DATE     / 1000.))

machine_breakdown_df <- read_csv2(file = "data/machine_breakdown_table.csv") %>%
  mutate(BREAKDOWN_BEGIN_DATE = as_datetime(BREAKDOWN_BEGIN_DATE / 1000.),
         BREAKDOWN_END_DATE   = as_datetime(BREAKDOWN_END_DATE   / 1000.))

machine_table <- read_csv2(file = "data/machine_table.csv")

# Merge lot process, arrival and routing info into one dataframe, then derive
# WORKSHOP_BEGIN_DATE: the date a lot enters a workshop, i.e. either the end
# date of its previous operation, or its fab arrival date for the first
# operation of a lot. Data is restricted to the study period.
lot_detailed_df <- lot_process_df %>%
  left_join(lot_arrival_df) %>%
  left_join(product_route_df) %>%
  select(LOT, PRODUCT, OPERATION, WORKSHOP, MACHINE,
         PROCESS_BEGIN_DATE, PROCESS_END_DATE, ARRIVAL_DATE) %>%
  arrange(LOT, PROCESS_BEGIN_DATE) %>%
  mutate(WORKSHOP_BEGIN_DATE = lag(PROCESS_END_DATE),
         WORKSHOP_BEGIN_DATE = ifelse(is.na(lag(LOT)) | lag(LOT) != LOT,
                                      ARRIVAL_DATE,
                                      WORKSHOP_BEGIN_DATE),
         WORKSHOP_BEGIN_DATE = as_datetime(WORKSHOP_BEGIN_DATE)) %>%
  filter(WORKSHOP_BEGIN_DATE <= as_datetime("2024-09-01") &
           PROCESS_END_DATE   >= as_datetime("2023-03-01"))

# ------------------------------------------------------------------------------
# 2. Cycle time per product
# ------------------------------------------------------------------------------
# W       = time spent waiting/processing within a single workshop step (days)
# W_total = total cycle time from fab arrival to end of an operation (days)

waiting_detailed_df <- lot_detailed_df %>%
  mutate(W       = (as.double(PROCESS_END_DATE) -
                      as.double(WORKSHOP_BEGIN_DATE)) / (24 * 3600),
         W_total = (as.double(PROCESS_END_DATE) -
                      as.double(ARRIVAL_DATE))        / (24 * 3600))

product_route_df_last_step <- product_route_df %>%
  group_by(PRODUCT) %>%
  mutate(LAST_OPERATION = OPERATION == OPERATION[[length(OPERATION)]]) %>%
  filter(LAST_OPERATION)

# Mean and std dev of total cycle time per product, for lots whose last
# operation completed within the study period
cycle_time_summary <- waiting_detailed_df %>%
  left_join(product_route_df_last_step) %>%
  filter(LAST_OPERATION == TRUE,
         PROCESS_END_DATE >= as_datetime("2023-03-01"),
         PROCESS_END_DATE <= as_datetime("2024-09-01")) %>%
  group_by(PRODUCT) %>%
  summarize(W_total_mean = mean(W_total),
            W_total_sd   = sd(W_total))

print(cycle_time_summary)

# Bar plot: mean per-step waiting time by product and workshop
p1 <- waiting_detailed_df %>%
  filter(PROCESS_END_DATE >= as_datetime("2023-03-01"),
         PROCESS_END_DATE <= as_datetime("2024-09-01")) %>%
  group_by(PRODUCT, WORKSHOP) %>%
  summarize(W_mean = mean(W)) %>%
  ggplot(aes(PRODUCT, W_mean, fill = WORKSHOP)) +
  geom_col() +
  labs(title = "Mean per-step waiting time by product and workshop",
       x = "Product", y = "Mean waiting time (days)")

ggsave("plots/bar_plot_waiting_time.png", plot = p1, width = 10, height = 6, dpi = 300)

# ------------------------------------------------------------------------------
# 3. Workshop occupation levels (WIP — Work In Process)
# ------------------------------------------------------------------------------
# L_machine  = lots currently being processed on a machine
# L_workshop = total lots present in the workshop (queued + processed)
# Computed via cumulative sum of entry/exit events, weighted by time spent
# at each occupation level.

list_days <- list(seq(as_datetime("2023-03-02"),
                      as_datetime("2024-09-01"), by = 24 * 3600))

check_event_df <- tibble(LOT       = NA,
                         OPERATION = NA,
                         WORKSHOP  = c("LITHOGRAPHY", "IMPLEMENTATION", "ETCHING"),
                         EVENT     = "CHECK",
                         DATE      = list_days) %>%
  unnest(c("DATE")) %>%
  mutate(DATE = round_date(DATE, unit = "days"))

occupation_event_df <- lot_detailed_df %>%
  select(-PRODUCT, -ARRIVAL_DATE, -MACHINE) %>%
  gather(key   = "EVENT",
         value = "DATE",
         WORKSHOP_BEGIN_DATE,
         PROCESS_BEGIN_DATE,
         PROCESS_END_DATE) %>%
  mutate(DATE = as_datetime(DATE)) %>%
  rbind(check_event_df) %>%
  arrange(WORKSHOP, DATE)

occupation_detailed_df <- occupation_event_df %>%
  group_by(WORKSHOP) %>%
  mutate(L_machine  = cumsum(EVENT == "PROCESS_BEGIN_DATE") -
           cumsum(EVENT == "PROCESS_END_DATE"),
         L_workshop = cumsum(EVENT == "WORKSHOP_BEGIN_DATE") -
           cumsum(EVENT == "PROCESS_END_DATE"),
         prev_DATE  = lag(DATE),
         prev_DATE  = ifelse(is.na(prev_DATE),
                             as_datetime("2023-03-01"),
                             prev_DATE),
         delta_time = as.double(DATE) - as.double(prev_DATE)) %>%
  gather(key = "L_type", value = "l", L_machine, L_workshop) %>%
  group_by(WORKSHOP, L_type) %>%
  mutate(occupation_cumul_load = cumsum(l * delta_time))

# Time-weighted mean and std dev of WIP by workshop
wip_summary <- occupation_detailed_df %>%
  filter(DATE >= as_datetime("2023-03-01") &
           DATE <= as_datetime("2024-09-01")) %>%
  group_by(L_type, WORKSHOP) %>%
  summarize(L_mean = sum(l * delta_time) / sum(delta_time),
            L_sd   = sqrt(sum(l^2 * delta_time) / sum(delta_time) -
                            (sum(l * delta_time) / sum(delta_time))^2)) %>%
  arrange(WORKSHOP)

print(wip_summary)

# Line plot: daily occupation level evolution by workshop (log scale)
p2 <- occupation_detailed_df %>%
  filter(EVENT == "CHECK") %>%
  mutate(L = (occupation_cumul_load - lag(occupation_cumul_load)) / (24 * 3600),
         L = ifelse(is.na(L), occupation_cumul_load / (24 * 3600), L)) %>%
  ggplot(aes(DATE, L, colour = WORKSHOP, linetype = L_type)) +
  geom_line() +
  scale_y_log10() +
  labs(title = "Daily occupation level by workshop (log scale)",
       x = "Date", y = "Occupation level (log scale)")

ggsave("plots/occupation_level.png", plot = p2, width = 10, height = 6, dpi = 300)

# ------------------------------------------------------------------------------
# 4. Machine utilization and breakdown rates
# ------------------------------------------------------------------------------

total_days <- length(list_days[[1]])

machine_detailed_stats <- lot_detailed_df %>%
  filter(PROCESS_END_DATE >= as_datetime("2023-03-01"),
         PROCESS_END_DATE <= as_datetime("2024-09-01")) %>%
  group_by(WORKSHOP, MACHINE) %>%
  summarize(utilisation      = sum(as.double(PROCESS_END_DATE) -
                                     as.double(PROCESS_BEGIN_DATE)) / 3600,
            utilisation_rate = utilisation / (total_days * 24)) %>%
  left_join(
    machine_breakdown_df %>%
      left_join(machine_table) %>%
      group_by(WORKSHOP, MACHINE) %>%
      mutate(BREAKDOWN_BEGIN_DATE = pmax(BREAKDOWN_BEGIN_DATE,
                                         as_datetime("2023-03-01")),
             BREAKDOWN_END_DATE   = pmin(BREAKDOWN_END_DATE,
                                         as_datetime("2024-09-01"))) %>%
      filter(BREAKDOWN_BEGIN_DATE < BREAKDOWN_END_DATE) %>%
      summarize(breakdown_time = sum(as.double(BREAKDOWN_END_DATE) -
                                       as.double(BREAKDOWN_BEGIN_DATE)) / 3600,
                breakdown_rate = breakdown_time / (total_days * 24))
  ) %>%
  arrange(desc(utilisation_rate))

# Mean utilization / breakdown rate by workshop
utilization_summary <- machine_detailed_stats %>%
  group_by(WORKSHOP) %>%
  summarize(nb_machines      = n(),
            utilisation_rate = mean(utilisation_rate, na.rm = TRUE),
            breakdown_rate   = mean(breakdown_rate,   na.rm = TRUE))

print(utilization_summary)

# ------------------------------------------------------------------------------
# 5. Bottleneck analysis — theoretical maximum throughput per workshop
# ------------------------------------------------------------------------------
# lambda_max = c / (S_mean * n_ops), where c is the number of machines,
# S_mean the mean processing time per operation (hours), and n_ops the
# number of distinct operations routed through the workshop. The workshop
# with the lowest lambda_max is the fab's production bottleneck.

bottleneck_summary <- lot_process_df %>%
  left_join(product_route_df) %>%
  filter(PROCESS_BEGIN_DATE >= as_datetime("2023-03-01"),
         PROCESS_END_DATE   <= as_datetime("2024-09-01")) %>%
  mutate(S = as.double(PROCESS_END_DATE) - as.double(PROCESS_BEGIN_DATE)) %>%
  group_by(WORKSHOP) %>%
  summarize(S_mean = mean(S) / 3600,
            c      = n_distinct(MACHINE)) %>%
  left_join(
    product_route_df %>%
      group_by(WORKSHOP) %>%
      summarize(n_ops = n())
  ) %>%
  mutate(lambda_max = c / (S_mean * n_ops)) %>%
  arrange(lambda_max)

print(bottleneck_summary)
