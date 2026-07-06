library(data.table)
library(terra)

source(file.path("R", "blackmarble_urbanicity_functions.R"))

tile_file <- file.path(
    "data", "raw", "blackmarble_h5", "VNP46A4.A2016001.h17v07.002.2025101113454.h5"
)
point_file <- file.path("data", "processed", "simulated_chain_gps_data_urbanicity.csv")
site_name <- "Banfora"

if (!file.exists(tile_file)) {
    stop("Tile file not found: ", tile_file)
}

if (!file.exists(point_file)) {
    stop("Point file not found: ", point_file)
}

blackmarble_raster <- blackmarble_h5_to_raster(
    tile_file,
    variable = "NearNadir_Composite_Snow_Free"
)

gps_data <- fread(point_file, na.strings = c(".", "NA"))
site_points <- gps_data[site == site_name]

if (!nrow(site_points)) {
    stop("No points found for site: ", site_name)
}

site_extent <- ext(
    min(site_points$Longitude) - 0.2,
    max(site_points$Longitude) + 0.2,
    min(site_points$Latitude) - 0.2,
    max(site_points$Latitude) + 0.2
)

site_crop <- crop(blackmarble_raster, site_extent)

png(
    filename = "banfora_blackmarble_tile.png",
    width = 1800,
    height = 1400,
    res = 180
)
plot(
    blackmarble_raster,
    main = "Black Marble 2016 Tile h17v07",
    col = hcl.colors(64, "YlOrRd", rev = TRUE)
)
points(
    site_points$Longitude,
    site_points$Latitude,
    pch = 21,
    bg = "deepskyblue",
    col = "black",
    cex = 1.1
)
text(
    site_points$Longitude,
    site_points$Latitude,
    labels = site_points$record_id,
    pos = 4,
    cex = 0.55,
    offset = 0.35
)
dev.off()

png(
    filename = "banfora_blackmarble_points_map.png",
    width = 1800,
    height = 1400,
    res = 180
)
plot(
    site_crop,
    main = "Banfora Points on Black Marble 2016",
    col = hcl.colors(64, "YlOrRd", rev = TRUE)
)
points(
    site_points$Longitude,
    site_points$Latitude,
    pch = 21,
    bg = "cyan",
    col = "black",
    cex = 1.3
)
text(
    site_points$Longitude,
    site_points$Latitude,
    labels = site_points$record_id,
    pos = 4,
    cex = 0.65,
    offset = 0.35
)
dev.off()