library(data.table)

set.seed(20260703)

output_file <- file.path("data", "simulated_chain_gps_data.csv")
n_per_site <- 10

site_lookup <- data.table(
    site = c(
        "Kilifi", "Nairobi", "Migori", "Kampala", "Blantyre",
        "Karachi", "Dhaka", "Matlab", "Banfora"
    ),
    country = c(
        "Kenya", "Kenya", "Kenya", "Uganda", "Malawi",
        "Pakistan", "Bangladesh", "Bangladesh", "Burkina Faso"
    ),
    lon_center = c(
        39.85, 36.82, 34.47, 32.58,
        35.01, 67.00, 90.41, 90.73, -4.77
    ),
    lat_center = c(
        -3.63, -1.29, -1.06, 0.35,
        -15.79, 24.86, 23.81, 23.38, 10.63
    )
)

simulate_chain_gps <- function(site_lookup, n_per_site = 10) {
    date_pool <- seq(as.IDate("2016-01-01"), as.IDate("2020-12-31"), by = "day")
    gps_data <- site_lookup[rep(seq_len(.N), each = n_per_site)]

    gps_data[, record_id := sprintf(
        "%02d%s",
        seq_len(.N),
        tolower(gsub("[^a-zA-Z0-9]", "", site))
    ),
    by = site
    ]
    gps_data[, Longitude := lon_center + rnorm(.N, sd = 0.08)]
    gps_data[, Latitude := lat_center + rnorm(.N, sd = 0.08)]
    gps_data[, adm_date := sample(date_pool, .N)]

    gps_data[, .(record_id, site, country, Longitude, Latitude, adm_date)]
}

dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)

gps_data <- simulate_chain_gps(site_lookup, n_per_site)
fwrite(gps_data, output_file, na = ".")

cat("Wrote simulated GPS input to:", output_file, "\n")
