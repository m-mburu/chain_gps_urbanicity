library(data.table)
library(here)
library(sf)

gps_file <- here(
    "data", "processed", "chain_data",
    "CHAIN_gpsdata_20260708_urbanicity.csv"
)
boundary_root <- here("data", "raw", "boundaries", "hdx_admin_boundaries")
output_file <- here(
    "data", "processed", "chain_data", "chain_site_sf_objects.rda"
)
manifest_file <- here(
    "data", "processed", "chain_data", "chain_site_sf_objects_manifest.csv"
)

site_targets <- data.table(
    object_name = c(
        "migori", "nairobi", "kilifi", "kampala", "blantyre",
        "banfora", "karachi", "dhaka", "matlab"
    ),
    source_site = c(
        "Migori", "Mbagathi", "Kilifi", "Kampala", "Blantyre",
        "Banfora", "Karachi", "Dhaka", "Matlab"
    ),
    display_site = c(
        "Migori", "Nairobi", "Kilifi", "Kampala", "Blantyre",
        "Banfora", "Karachi", "Dhaka", "Matlab"
    ),
    country = c(
        "Kenya", "Kenya", "Kenya", "Uganda", "Malawi",
        "Burkina Faso", "Pakistan", "Bangladesh", "Bangladesh"
    ),
    iso3 = c("ken", "ken", "ken", "uga", "mwi", "bfa", "pak", "bgd", "bgd")
)

required_gps_cols <- c(
    "record_id", "site", "longitude", "latitude", "adm_date", "degree_urban"
)

read_chain_gps <- function(path) {
    if (!file.exists(path)) {
        stop("Urbanicity-added GPS file not found: ", path)
    }

    gps_data <- fread(path, na.strings = c(".", "NA", ""))
    missing_cols <- setdiff(required_gps_cols, names(gps_data))
    if (length(missing_cols)) {
        stop(
            "GPS file is missing required columns: ",
            paste(missing_cols, collapse = ", ")
        )
    }

    gps_data[, adm_date := as.IDate(adm_date)]
    gps_data[]
}

make_point_sfc <- function(longitude, latitude, crs = 4326) {
    st_sfc(lapply(seq_along(longitude), function(i) {
        if (is.na(longitude[i]) || is.na(latitude[i])) {
            return(st_point())
        }

        st_point(c(longitude[i], latitude[i]))
    }), crs = crs)
}

find_admin_boundary_file <- function(iso3) {
    shp_files <- list.files(
        file.path(boundary_root, iso3),
        pattern = paste0("^", iso3, "_admin[0-9]+\\.shp$"),
        recursive = TRUE,
        full.names = TRUE,
        ignore.case = TRUE
    )

    shp_files <- shp_files[!grepl("_em\\.shp$", shp_files, ignore.case = TRUE)]
    if (!length(shp_files)) {
        stop("No HDX admin boundary shapefile found for ISO3: ", iso3)
    }

    admin_levels <- as.integer(sub(
        paste0(".*", iso3, "_admin([0-9]+)\\.shp$"),
        "\\1",
        shp_files,
        ignore.case = TRUE
    ))
    shp_files[which.max(admin_levels)]
}

read_admin_boundaries <- function(iso3) {
    boundary_file <- find_admin_boundary_file(iso3)
    boundaries <- st_read(boundary_file, quiet = TRUE)
    boundaries <- st_make_valid(boundaries)
    boundaries <- st_transform(boundaries, 4326)

    attr(boundaries, "boundary_file") <- boundary_file
    boundaries
}

select_patient_support_units <- function(patient_sf, boundaries) {
    patient_points <- patient_sf[!st_is_empty(patient_sf), ]
    if (!nrow(patient_points)) {
        return(boundaries[0, ])
    }

    hits <- st_intersects(patient_points, boundaries)
    support_index <- sort(unique(unlist(hits, use.names = FALSE)))

    missed <- which(lengths(hits) == 0L)
    if (length(missed)) {
        nearest_index <- st_nearest_feature(
            patient_points[missed, ], boundaries
        )
        support_index <- sort(unique(c(support_index, nearest_index)))
    }

    boundaries[support_index, ]
}

make_site_sf <- function(gps_data, target, boundaries_by_iso3) {
    site_data <- copy(gps_data[site == target$source_site])
    if (!nrow(site_data)) {
        stop("No GPS rows found for site: ", target$source_site)
    }

    site_data[, `:=`(
        site_object = target$object_name,
        display_site = target$display_site,
        source_site = target$source_site,
        country = target$country,
        iso3 = target$iso3
    )]

    site_data[, geometry := make_point_sfc(longitude, latitude)]
    site_sf <- st_as_sf(site_data, sf_column_name = "geometry", crs = 4326)

    boundaries <- boundaries_by_iso3[[target$iso3]]
    support_units <- select_patient_support_units(site_sf, boundaries)
    support_geometry <- st_sf(
        site_object = target$object_name,
        display_site = target$display_site,
        source_site = target$source_site,
        country = target$country,
        iso3 = target$iso3,
        n_support_units = nrow(support_units),
        geometry = if (nrow(support_units)) {
            st_sfc(st_union(st_geometry(support_units)), crs = st_crs(boundaries))
        } else {
            st_sfc(st_geometrycollection(), crs = st_crs(boundaries))
        }
    )

    attr(site_sf, "patient_support_geometry") <- support_geometry
    attr(site_sf, "patient_support_boundary_file") <- attr(boundaries, "boundary_file")
    attr(site_sf, "patient_support_unit_count") <- nrow(support_units)

    site_sf
}

gps_data <- read_chain_gps(gps_file)
dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)

boundaries_by_iso3 <- lapply(unique(site_targets$iso3), read_admin_boundaries)
names(boundaries_by_iso3) <- unique(site_targets$iso3)

chain_site_sf_objects <- lapply(seq_len(nrow(site_targets)), function(i) {
    make_site_sf(gps_data, site_targets[i], boundaries_by_iso3)
})
names(chain_site_sf_objects) <- site_targets$object_name

manifest <- rbindlist(lapply(names(chain_site_sf_objects), function(object_name) {
    site_sf <- chain_site_sf_objects[[object_name]]

    data.table(
        object_name = object_name,
        source_site = unique(site_sf$source_site),
        display_site = unique(site_sf$display_site),
        country = unique(site_sf$country),
        iso3 = unique(site_sf$iso3),
        n_rows = nrow(site_sf),
        n_missing_gps = sum(st_is_empty(site_sf)),
        n_missing_degree_urban = sum(is.na(site_sf$degree_urban)),
        n_support_units = attr(site_sf, "patient_support_unit_count"),
        support_boundary_file = attr(site_sf, "patient_support_boundary_file")
    )
}), fill = TRUE)

save(chain_site_sf_objects, file = output_file, compress = "xz")
fwrite(manifest, manifest_file)

cat("Saved site sf object list to:", output_file, "\n")
cat("Wrote manifest to:", manifest_file, "\n")
