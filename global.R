library(shiny)
library(bslib)
library(ChainLadder)
library(dplyr)
library(tidyr)
library(plotly)
library(DT)
library(DBI)
library(duckdb)

# Fetch data from the database
con <- dbConnect(duckdb::duckdb(), dbdir = "insurance_reserving.duckdb")
long_triangle <- dbGetQuery(con, "SELECT * FROM v_incremental_triangle")
dbDisconnect(con, shutdown = TRUE) # Close immediately so the file isn't locked

# Enforce the 10x10 Actuarial Grid
full_grid <- expand.grid(
  accident_year = 2016:2025,
  dev_year = 1:10
)

clean_long <- full_grid %>%
  left_join(long_triangle, by = c("accident_year", "dev_year")) %>%
  mutate(
    calendar_year = accident_year + dev_year - 1,
    incremental_paid = case_when(
      calendar_year <= 2025 & is.na(incremental_paid) ~ 0,       
      calendar_year > 2025 ~ NA_real_,                           
      TRUE ~ incremental_paid
    )
  )

matrix_triangle <- clean_long %>%
  select(-calendar_year) %>%
  pivot_wider(names_from = dev_year, values_from = incremental_paid) %>%
  arrange(accident_year)

# Format for ChainLadder package
tri_matrix <- as.matrix(matrix_triangle[, -1])
rownames(tri_matrix) <- matrix_triangle$accident_year

cumul_triangle <- t(apply(tri_matrix, 1, cumsum))
cumul_triangle <- as.triangle(cumul_triangle)
