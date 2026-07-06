# Build the README example maps of nighttime lights with patient points.
# Run R/process_blackmarble_urbanicity.R first so the output CSV, manifest,
# and cached Black Marble H5 files exist.

library(data.table)
library(sf)
library(terra)
library(ggplot2)

source(file.path("R", "blackmarble_urbanicity_functions.R"))

example_sites <- c("Nairobi", "Migori")
target_year <- 2020
gps_cols <- c("Longitude", "Latitude")
point_file <- file.path("data", "processed", "simulated_chain_gps_data_urbanicity.csv")
manifest_file <- file.path("data", "metadata", "blackmarble_download_log.csv")
county_file <- file.path("data", "raw", "boundaries", "kenya_counties", "County.shp")
output_files <- c(
    Nairobi = file.path("data", "processed", "nairobi_blackmarble_patients.png"),
    Migori = file.path("data", "processed", "migori_blackmarble_patients.png")
)

read_county_boundary <- function(county_file, site_name) {
    county_sf <- st_read(county_file, quiet = TRUE)
    county_sf <- st_transform(county_sf, 4326)
    county_sf <- county_sf[county_sf$COUNTY == site_name, ]

    if (!nrow(county_sf)) {
        stop("County shapefile is missing: ", site_name)
    }

    county_sf
}

read_site_blackmarble_raster <- function(manifest, site_name, target_year) {
    manifest_rows <- manifest[site == site_name & adm_year == target_year]
    manifest_rows <- manifest_rows[file.exists(local_path)]

    if (!nrow(manifest_rows)) {
        stop(
            "No cached Black Marble H5 files found for ", site_name,
            " in ", target_year, ". Run R/process_blackmarble_urbanicity.R first."
        )
    }

    raster_list <- lapply(manifest_rows$local_path, blackmarble_h5_to_raster)
    if (length(raster_list) == 1) {
        return(raster_list[[1]])
    }

    do.call(terra::mosaic, c(raster_list, fun = "max"))
}

plot_blackmarble_patients <- function(
  county_sf,
  patient_points,
  blackmarble_raster,
  gps_cols = c("Longitude", "Latitude"),
  title,
  output_file
) {
    gps_cols <- validate_gps_cols(gps_cols)

    county_vect <- terra::vect(county_sf)
    blackmarble_raster <- terra::crop(blackmarble_raster, county_vect)
    blackmarble_raster <- terra::mask(blackmarble_raster, county_vect)
    names(blackmarble_raster) <- "radiance"

    raster_df <- as.data.table(terra::as.data.frame(
        blackmarble_raster,
        xy = TRUE,
        na.rm = FALSE
    ))
    raster_df[, log_lights := log(radiance + 1)]

    cell_width <- min(diff(sort(unique(raster_df$x))), na.rm = TRUE)
    cell_height <- min(diff(sort(unique(raster_df$y))), na.rm = TRUE)

    map <- ggplot() +
        geom_tile(
            data = raster_df,
            aes(x = x, y = y, fill = log_lights),
            width = cell_width,
            height = cell_height
        ) +
        geom_point(
            data = patient_points,
            aes(x = .data[[gps_cols[1]]], y = .data[[gps_cols[2]]]),
            color = "deepskyblue",
            size = 2
        ) +
        scale_fill_gradient2(
            low = "black",
            mid = "yellow",
            high = "red",
            midpoint = 4.5,
            na.value = "transparent"
        ) +
        coord_equal(expand = FALSE) +
        labs(title = title) +
        theme_void() +
        theme(
            plot.title = element_text(face = "bold", hjust = 0.5),
            legend.position = "none"
        )

    dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
    ggsave(output_file, map, width = 7, height = 7, dpi = 180)
    cat("Wrote README example map to:", output_file, "\n")
    invisible(map)
}

if (!file.exists(point_file)) {
    stop("Point file not found: ", point_file, "\nRun R/process_blackmarble_urbanicity.R first.")
}
if (!file.exists(manifest_file)) {
    stop("Manifest file not found: ", manifest_file, "\nRun R/process_blackmarble_urbanicity.R first.")
}
if (!file.exists(county_file)) {
    stop("County shapefile not found: ", county_file)
}

gps_cols <- validate_gps_cols(gps_cols)
gps_data <- fread(point_file, na.strings = c(".", "NA"))
gps_data[, adm_date := as.IDate(adm_date)]
gps_data[, adm_year := as.integer(format(adm_date, "%Y"))]
manifest <- fread(manifest_file, na.strings = c("", ".", "NA"))

for (site_name in example_sites) {
    patient_points <- gps_data[site == site_name]
    if (!nrow(patient_points)) {
        stop("No patient points found for: ", site_name)
    }

    county_sf <- read_county_boundary(county_file, site_name)
    blackmarble_raster <- read_site_blackmarble_raster(
        manifest = manifest,
        site_name = site_name,
        target_year = target_year
    )

    plot_blackmarble_patients(
        county_sf = county_sf,
        patient_points = patient_points,
        blackmarble_raster = blackmarble_raster,
        gps_cols = gps_cols,
        title = paste("Nighttime Lights:", site_name, target_year),
        output_file = output_files[[site_name]]
    )
}