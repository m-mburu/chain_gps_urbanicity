library(data.table)
library(here)
source(here("R", "blackmarble_urbanicity_functions.R"))

# Local private-data run. The CHAIN export uses date_adm, which is renamed
# below to adm_date for the shared Black Marble helper functions.

input_file <- here("data", "raw", "chain_data", "CHAIN_gpsdata_20260708.csv")
output_file <- here(
    "data", "processed", "chain_data",
    "CHAIN_gpsdata_20260708_urbanicity.csv"
)
h5_dir <- here("data", "raw", "blackmarble_h5")
log_file <- here(
    "data", "processed", "chain_data", "blackmarble_download_log.csv"
)
gps_cols <- c("longitude", "latitude")

parse_chain_adm_date <- function(x) {
    x <- trimws(as.character(x))
    x[x == ""] <- NA_character_

    date_parts <- tstrsplit(x, "-", fixed = TRUE)
    if (length(date_parts) != 3) {
        stop("adm_date must use a format like 15-Nov-16.")
    }

    day <- as.integer(date_parts[[1]])
    month_lookup <- c(
        jan = 1L, feb = 2L, mar = 3L, apr = 4L,
        may = 5L, jun = 6L, jul = 7L, aug = 8L,
        sep = 9L, oct = 10L, nov = 11L, dec = 12L
    )
    month <- unname(month_lookup[tolower(date_parts[[2]])])
    year_text <- date_parts[[3]]
    year <- as.integer(year_text)
    year <- ifelse(
        nchar(year_text) == 2L,
        ifelse(year <= 68L, 2000L + year, 1900L + year),
        year
    )

    parsed <- as.IDate(sprintf("%04d-%02d-%02d", year, month, day))
    bad_dates <- !is.na(x) & is.na(parsed)
    if (any(bad_dates)) {
        stop(
            "Could not parse adm_date for ", sum(bad_dates),
            " row(s). Expected dates like 15-Nov-16."
        )
    }

    parsed
}
ensure_blackmarble_storage_paths(
    input_file = input_file,
    output_file = output_file,
    h5_dir = h5_dir,
    log_file = log_file
)

if (!file.exists(input_file)) {
    stop(
        "Input file not found: ", input_file, "\n",
        "Check that the private CHAIN GPS export exists, or\n",
        "replace input_file with the current private GPS export."
    )
}

gps_data <- fread(input_file, na.strings = c(".", "NA"))
if ("date_adm" %in% names(gps_data) && !("adm_date" %in% names(gps_data))) {
    setnames(gps_data, "date_adm", "adm_date")
}
gps_data[, adm_date := parse_chain_adm_date(adm_date)]

complete_marble_rows <- !is.na(gps_data[[gps_cols[1]]]) &
    !is.na(gps_data[[gps_cols[2]]]) &
    !is.na(gps_data[["adm_date"]])

gps_data_for_marble <- gps_data[complete_marble_rows]
gps_data_for_imputation <- gps_data[!complete_marble_rows]

bearer <- setup_blackmarble_downloads(Sys.getenv("LAADS_DAAC"))

gps_data_urbanicity <- add_blackmarble_degree_urban(
    gps_data_for_marble,
    bearer = bearer,
    h5_dir = h5_dir,
    log_file = log_file,
    gps_cols = gps_cols
)

if (nrow(gps_data_for_imputation)) {
    gps_data_for_imputation[, degree_urban := NA_real_]
    gps_data_urbanicity <- rbindlist(
        list(gps_data_urbanicity, gps_data_for_imputation),
        use.names = TRUE,
        fill = TRUE
    )
}
setorder(gps_data_urbanicity, record_id)

fwrite(gps_data_urbanicity, output_file, na = ".")

cat("Wrote urbanicity output to:", output_file, "\n")
cat("Wrote Black Marble manifest to:", log_file, "\n")