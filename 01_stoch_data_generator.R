# Load libraries
library(dplyr)
library(lubridate)
library(purrr)

# Global parameters and init
set.seed(42)
evaluation_date <- ymd("2025-12-31")
start_date <- evaluation_date - years(9) # 10 full accident years
years_seq <- 0:9

# Simulation parameters
base_lambda <- 1500      # Base number of claims per year, normally depends on LOB but for simplicity (and computing) we keep it relatively low
growth_rate <- 1.05      # 5% annual portfolio growth (3-5 is okay)
mu_severity <- 8.5       # Log-Normal mean
sigma_severity <- 1.5    # Log-Normal sd
inflation_rate <- 1.04   # 4% annual severity inflation

# Simulate claim counts
# Let's assume the number of claims per year follows a Poisson distribution
claims_per_year <- rpois(length(years_seq), lambda = base_lambda * (growth_rate ^ years_seq))

claims_df <- tibble(
  accident_year = rep(year(start_date) + years_seq, claims_per_year)
) %>%
  mutate(
    claim_id = row_number(),
    # Distribute accident dates uniformly throughout the year
    accident_date = make_date(accident_year, 1, 1) + 
      days(sample(0:364, n(), replace = TRUE))
  )

# Simulate Severity & Reporting Delay
claims_df <- claims_df %>%
  mutate(
    # Ultimate claim cost follows a right-skewed Log-Normal distribution, adjusted for inflation
    ultimate_incurred = rlnorm(n(), mu_severity, sigma_severity) * (inflation_rate ^ (accident_year - min(accident_year))),
    
    # Reporting delay follows a Weibull distribution (most reported quickly, long right tail)
    report_delay_days = rweibull(n(), shape = 1.2, scale = 30),
    report_date = accident_date + days(round(report_delay_days))
  ) %>%
  # Filter out claims reported after our evaluation date (Incurred But Not Reported - IBNR)
  filter(report_date <= evaluation_date)


# Simulate Incremental Transactions

# Function to split an ultimate claim into 1 to 5 random incremental payments
generate_transactions <- function(id, report_dt, ultimate_amt) {
  num_payments <- sample(1:5, 1, prob = c(0.4, 0.3, 0.15, 0.1, 0.05))
  
  # Generate random payment dates after the report date
  payment_delays <- cumsum(rexp(num_payments, rate = 1/90)) # ~90 days between payments
  transaction_dates <- report_dt + days(round(payment_delays))
  
  # Apportion the ultimate amount across the transactions
  payment_proportions <- runif(num_payments)
  payment_proportions <- payment_proportions / sum(payment_proportions)
  payment_amounts <- ultimate_amt * payment_proportions
  
  tibble(
    claim_id = id,
    transaction_date = transaction_dates,
    payment_amount = payment_amounts
  )
}

# Apply the function to all claims
transactions_df <- claims_df %>%
  select(claim_id, report_date, ultimate_incurred) %>%
  pmap_dfr(~generate_transactions(..1, ..2, ..3)) %>%
  # Cap transaction dates at the evaluation date
  filter(transaction_date <= evaluation_date)


# Inject Anomalies (noise to make the data close to reality)
n_trans <- nrow(transactions_df)

# Transactions closed without payment
transactions_df$payment_amount[sample(1:n_trans, size = n_trans * 0.05)] <- 0

# Subrogation presetned as negative payments (reimbursements)
transactions_df$payment_amount[sample(1:n_trans, size = n_trans * 0.02)] <- 
  -abs(rnorm(n_trans * 0.02, mean = 500, sd = 100))

# Adding some dates reporting inconsistencies to simulate human error
transactions_df <- transactions_df %>%
  left_join(claims_df %>% select(claim_id, accident_date), by = "claim_id") %>%
  mutate(
    # Randomly format some dates as DD/MM/YYYY instead of YYYY-MM-DD
    transaction_date_str = if_else(
      runif(n()) > 0.8,
      format(transaction_date, "%d/%m/%Y"),
      as.character(transaction_date)
    )
  ) %>%
  select(claim_id, accident_date, transaction_date = transaction_date_str, payment_amount) %>%
  arrange(transaction_date)

transactions_df <- transactions_df %>%
  mutate(payment_amount = round(payment_amount, 2))

write.csv(transactions_df, "raw_claims_transactions.csv", row.names = FALSE)
cat("Generated", nrow(transactions_df), "transactions.\n")
