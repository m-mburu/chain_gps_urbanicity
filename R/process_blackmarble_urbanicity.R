library(data.table)
library(here)
source(here("R", "blackmarble_urbanicity_functions.R"))

# For a real data set, point input_file to that CSV. The required columns are:
# record_id, site, adm_date, and the two coordinate columns named in gps_cols.

input_file <- here("data", "simulated_chain_gps_data.csv")
output_file <- here(
    "data", "processed", "simulated_chain_gps_data_urbanicity.csv"
)
h5_dir <- here("data", "raw", "blackmarble_h5")
log_file <- here("data", "metadata", "blackmarble_download_log.csv")
gps_cols <- c("Longitude", "Latitude")

ensure_blackmarble_storage_paths(
    input_file = input_file,
    output_file = output_file,
    h5_dir = h5_dir,
    log_file = log_file
)

if (!file.exists(input_file)) {
    stop(
        "Input file not found: ", input_file, "\n",
        "Run R/simulate_chain_gps_data.R first, or replace input_file\n",
        "with your real GPS data."
    )
}

gps_data <- fread(input_file, na.strings = c(".", "NA"))

bearer <- setup_blackmarble_downloads(Sys.getenv("LAADS_DAAC"))

gps_data_urbanicity <- add_blackmarble_degree_urban(
    gps_data,
    bearer = bearer,
    h5_dir = h5_dir,
    log_file = log_file,
    gps_cols = gps_cols
)
fwrite(gps_data_urbanicity, output_file, na = ".")

cat("Wrote urbanicity output to:", output_file, "\n")
cat("Wrote Black Marble manifest to:", log_file, "\n")