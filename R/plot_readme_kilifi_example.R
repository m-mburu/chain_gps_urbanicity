# Build the Kilifi example figure shown in README.Rmd.
# Run R/process_blackmarble_urbanicity.R first so the output CSV, manifest,
# and cached Black Marble H5 files exist.

library(data.table)
library(terra)
library(ggplot2)

source(file.path("R", "blackmarble_urbanicity_functions.R"))

site_name <- "Kilifi"
gps_cols <- c("Longitude", "Latitude")
point_file <- file.path("data", "processed", "simulated_chain_gps_data_urbanicity.csv")
manifest_file <- file.path("data", "metadata", "blackmarble_download_log.csv")
output_file <- file.path("data", "processed", "kilifi_blackmarble_facets.png")
buffer_deg <- 0.2

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
site_points <- gps_data[site == site_name]

if (!nrow(site_points)) {
    stop("No points found for site: ", site_name)
}

manifest <- fread(manifest_file, na.strings = c("", ".", "NA"))
manifest_rows <- manifest[site == site_name]
manifest_rows <- manifest_rows[file.exists(local_path)]

if (!nrow(manifest_rows)) {
    stop("No cached Black Marble H5 files found for ", site_name, ". Run processing first.")
}

site_extent <- ext(
    min(site_points[[gps_cols[1]]]) - buffer_deg,
    max(site_points[[gps_cols[1]]]) + buffer_deg,
    min(site_points[[gps_cols[2]]]) - buffer_deg,
    max(site_points[[gps_cols[2]]]) + buffer_deg
)

years <- sort(intersect(unique(site_points$adm_year), unique(manifest_rows$adm_year)))

raster_df <- rbindlist(lapply(years, function(year_i) {
    year_rows <- manifest_rows[adm_year == year_i]
    raster_list <- lapply(year_rows$local_path, blackmarble_h5_to_raster)
    raster_i <- if (length(raster_list) == 1) {
        raster_list[[1]]
    } else {
        do.call(terra::mosaic, c(raster_list, fun = "max"))
    }
    raster_i <- crop(raster_i, site_extent)
    names(raster_i) <- "radiance"
    raster_i <- terra::aggregate(raster_i, fact = 2, fun = mean, na.rm = TRUE)

    df <- as.data.table(terra::as.data.frame(raster_i, xy = TRUE, na.rm = FALSE))
    df[, adm_year := year_i]
    df[, log_lights := log(radiance + 1)]
    df
}), fill = TRUE)

cell_width <- min(diff(sort(unique(raster_df$x))), na.rm = TRUE)
cell_height <- min(diff(sort(unique(raster_df$y))), na.rm = TRUE)

plot_points <- copy(site_points)
plot_points <- plot_points[adm_year %in% years]

map <- ggplot() +
    geom_tile(
        data = raster_df,
        aes(x = x, y = y, fill = log_lights),
        width = cell_width,
        height = cell_height
    ) +
    geom_point(
        data = plot_points,
        aes(x = .data[[gps_cols[1]]], y = .data[[gps_cols[2]]]),
        shape = 21,
        fill = "deepskyblue",
        color = "black",
        size = 1.8,
        stroke = 0.25
    ) +
    scale_fill_gradient2(
        low = "black",
        mid = "yellow",
        high = "red",
        midpoint = 4.5,
        na.value = "transparent",
        name = "log lights"
    ) +
    facet_wrap(~adm_year) +
    coord_equal(expand = FALSE) +
    labs(
        title = "Kilifi GPS points on annual Black Marble nighttime lights",
        x = NULL,
        y = NULL
    ) +
    theme_void() +
    theme(
        plot.title = element_text(face = "bold", hjust = 0.5),
        strip.text = element_text(face = "bold"),
        legend.position = "bottom"
    )

dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
ggsave(output_file, map, width = 9, height = 6, dpi = 180)
cat("Wrote README example map to:", output_file, "\n")