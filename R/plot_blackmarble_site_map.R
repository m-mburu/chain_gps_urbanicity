# Optional visual check: map Black Marble nighttime lights for one site-year.
# Run the processing script first so the H5 tiles and manifest exist.

library(data.table)
library(sf)
library(terra)

source(file.path("R", "blackmarble_urbanicity_functions.R"))

site_name <- "Banfora"
target_year <- 2016
point_file <- file.path("data", "processed", "simulated_chain_gps_data_urbanicity.csv")
manifest_file <- file.path("data", "metadata", "blackmarble_download_log.csv")
gps_cols <- c("Longitude", "Latitude")
buffer_deg <- 0.2
output_file <- file.path(
    "data",
    "processed",
    paste0(tolower(gsub("[^A-Za-z0-9]+", "_", site_name)), "_", target_year, "_blackmarble_map.png")
)

if (!requireNamespace("ggplot2", quietly = TRUE) ||
    !requireNamespace("tidyterra", quietly = TRUE)) {
    stop("Install optional map packages first: install.packages(c('ggplot2', 'tidyterra'))")
}

if (!file.exists(point_file)) {
    stop("Point file not found: ", point_file, "\nRun R/process_blackmarble_urbanicity.R first.")
}

if (!file.exists(manifest_file)) {
    stop("Manifest file not found: ", manifest_file, "\nRun R/process_blackmarble_urbanicity.R first.")
}

gps_cols <- validate_gps_cols(gps_cols)
gps_data <- fread(point_file, na.strings = c(".", "NA"))
gps_data[, adm_date := as.IDate(adm_date)]
gps_data[, adm_year := as.integer(format(adm_date, "%Y"))]
site_points <- gps_data[site == site_name & adm_year == target_year]

if (!nrow(site_points)) {
    stop("No points found for ", site_name, " in ", target_year, ".")
}

manifest <- fread(manifest_file, na.strings = c("", ".", "NA"))
manifest_rows <- manifest[site == site_name & adm_year == target_year]
manifest_rows <- manifest_rows[file.exists(local_path)]

if (!nrow(manifest_rows)) {
    stop(
        "No cached Black Marble H5 files found in the manifest for ",
        site_name, " ", target_year, ".\nRun R/process_blackmarble_urbanicity.R first."
    )
}

raster_list <- lapply(manifest_rows$local_path, blackmarble_h5_to_raster)
blackmarble_raster <- if (length(raster_list) == 1) {
    raster_list[[1]]
} else {
    do.call(terra::mosaic, c(raster_list, fun = "max"))
}

site_extent <- ext(
    min(site_points[[gps_cols[1]]]) - buffer_deg,
    max(site_points[[gps_cols[1]]]) + buffer_deg,
    min(site_points[[gps_cols[2]]]) - buffer_deg,
    max(site_points[[gps_cols[2]]]) + buffer_deg
)
blackmarble_raster <- crop(blackmarble_raster, site_extent)

# "The radiance distribution is usually skewed, so log scaling makes the map
# easier to read without changing the extracted degree_urban values."
blackmarble_raster[] <- log(blackmarble_raster[] + 1)
site_points_sf <- st_as_sf(
    as.data.frame(site_points),
    coords = gps_cols,
    crs = 4326,
    remove = FALSE
)

map <- ggplot2::ggplot() +
    tidyterra::geom_spatraster(data = blackmarble_raster) +
    ggplot2::geom_sf(data = site_points_sf, shape = 21, fill = "deepskyblue", color = "black", size = 2.4) +
    ggplot2::scale_fill_gradient2(
        low = "black",
        mid = "yellow",
        high = "red",
        midpoint = 4.5,
        na.value = "transparent",
        name = "log lights"
    ) +
    ggplot2::labs(title = paste("Nighttime Lights:", site_name, target_year)) +
    ggplot2::coord_sf() +
    ggplot2::theme_void() +
    ggplot2::theme(
        plot.title = ggplot2::element_text(face = "bold", hjust = 0.5),
        legend.position = "none"
    )

dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
ggplot2::ggsave(output_file, map, width = 8, height = 6, dpi = 180)
print(map)

cat("Wrote map to:", output_file, "\n")