library(DBI)
library(duckdb)


con <- dbConnect(duckdb::duckdb(), dbdir = "insurance_reserving.duckdb")

dbExecute(con, "DROP TABLE IF EXISTS raw_transactions")

dbExecute(con, "
  CREATE TABLE raw_transactions AS 
  SELECT * FROM read_csv_auto('raw_claims_transactions.csv', all_varchar=true)
")

sql_query <- "
CREATE OR REPLACE VIEW v_incremental_triangle AS
WITH cleaned_data AS (
    SELECT 
        claim_id,
        COALESCE(TRY_CAST(accident_date AS DATE), strptime(accident_date, '%d/%m/%Y')::DATE) AS accident_date,
        COALESCE(TRY_CAST(transaction_date AS DATE), strptime(transaction_date, '%d/%m/%Y')::DATE) AS transaction_date,
        CAST(payment_amount AS DOUBLE) AS payment_amount
    FROM raw_transactions
),
triangle_base AS (
    SELECT 
        EXTRACT(YEAR FROM accident_date) AS accident_year,
        EXTRACT(YEAR FROM transaction_date) - EXTRACT(YEAR FROM accident_date) + 1 AS dev_year,
        payment_amount
    FROM cleaned_data
)
SELECT 
    accident_year,
    dev_year,
    SUM(payment_amount) AS incremental_paid
FROM triangle_base
WHERE dev_year BETWEEN 1 AND 10
GROUP BY accident_year, dev_year
ORDER BY accident_year, dev_year;
"

dbExecute(con, sql_query)
dbDisconnect(con, shutdown = TRUE)
