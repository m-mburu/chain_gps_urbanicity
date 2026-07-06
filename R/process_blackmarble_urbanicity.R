library(data.table)

source(file.path("R", "blackmarble_urbanicity_functions.R"))

# For a real data set, point input_file to that CSV. The required columns are:
# record_id, site, adm_date, and the two coordinate columns named in gps_cols.

input_file <- file.path("data", "simulated_chain_gps_data.csv")
output_file <- file.path("data", "processed", "simulated_chain_gps_data_urbanicity.csv")
h5_dir <- file.path("data", "raw", "blackmarble_h5")
log_file <- file.path("data", "metadata", "blackmarble_download_log.csv")
gps_cols <- c("Longitude", "Latitude")

if (!file.exists(input_file)) {
    stop(
        "Input file not found: ", input_file, "\n",
        "Run R/simulate_chain_gps_data.R first, or replace input_file with your real GPS data."
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

dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
fwrite(gps_data_urbanicity, output_file, na = ".")

cat("Wrote urbanicity output to:", output_file, "\n")
cat("Wrote Black Marble manifest to:", log_file, "\n")