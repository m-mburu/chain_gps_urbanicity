library(data.table)
library(sf)
library(terra)

# Clean and standardize the LAADS bearer token before any API requests.
normalize_laads_bearer <- function(bearer = Sys.getenv("LAADS_DAAC")) {
    # "The token is usually stored in .Renviron with quotes, for example
    # LAADS_DAAC="...". R normally removes those quotes when it starts, but
    # strip wrapping quotes here too so manually supplied values also work."
    bearer <- trimws(bearer)
    bearer <- gsub("^[\"']|[\"']$", "", bearer)
    bearer <- sub("^Bearer[[:space:]]*", "", bearer, ignore.case = TRUE)
    bearer <- gsub("[[:space:]]+", "", bearer)
    bearer <- gsub("^[\"']|[\"']$", "", bearer)

    if (!nzchar(bearer)) {
        stop("LAADS_DAAC environment variable is not set.")
    }

    bearer
}

# Convert a manifest path into a stable normalized string for logging.
normalize_manifest_path <- function(path) {
    # "Store readable, stable paths in the manifest without requiring the file
    # to exist yet; new downloads may be logged before users inspect them."
    if (is.null(path) || !nzchar(path)) {
        return(NA_character_)
    }

    normalizePath(path, winslash = "/", mustWork = FALSE)
}

# Return the first usable value in x, otherwise fall back to y.
`%||%` <- function(x, y) {
    # "Small helper: use x when it has a real value, otherwise fall back to y."
    if (is.null(x) || !length(x) || all(is.na(x))) {
        return(y)
    }

    x[1]
}

# Validate the longitude and latitude column names used in GPS inputs.
validate_gps_cols <- function(gps_cols) {
    # "gps_cols lets real data keep its own longitude/latitude column names.
    # The first value must be longitude and the second must be latitude."
    if (length(gps_cols) != 2 || anyNA(gps_cols) ||
        !all(nzchar(gps_cols))) {
        stop(
            "gps_cols must be a character vector like ",
            "c('Longitude', 'Latitude')."
        )
    }

    as.character(gps_cols)
}

# Create the generated storage directories used by the Black Marble workflow.
ensure_blackmarble_storage_paths <- function(
  input_file = NULL,
  output_file,
  h5_dir,
  log_file
) {
    # "These directories match the generated paths ignored in .gitignore:
    # data/raw/blackmarble_h5, data/metadata, and data/processed."
    candidate_dirs <- c(
        dirname(normalize_manifest_path(input_file)),
        dirname(normalize_manifest_path(output_file)),
        dirname(normalize_manifest_path(log_file)),
        dirname(normalize_manifest_path(h5_dir)),
        normalize_manifest_path(h5_dir)
    )

    candidate_dirs <- unique(candidate_dirs)
    candidate_dirs <- candidate_dirs[
        !is.na(candidate_dirs) &
            nzchar(candidate_dirs) &
            candidate_dirs != "."
    ]

    invisible(lapply(
        candidate_dirs,
        dir.create,
        recursive = TRUE,
        showWarnings = FALSE
    ))

    candidate_dirs
}

# Append or update the tile usage manifest for each site-year download.
append_blackmarble_manifest <- function(
  site,
  adm_year,
  tile_file,
  local_path,
  log_file
) {
    if (is.null(log_file) || !nzchar(log_file)) {
        return(invisible(NULL))
    }

    dir.create(dirname(log_file), recursive = TRUE, showWarnings = FALSE)

    # "Each manifest row says which site-year used which Black Marble tile.
    # The H5 filename stays unchanged; the site relationship lives in this CSV."
    new_row <- data.table(
        site = as.character(site %||% NA_character_),
        adm_year = as.integer(adm_year %||% NA_integer_),
        tile_file = basename(tile_file),
        local_path = normalize_manifest_path(local_path)
    )

    if (file.exists(log_file)) {
        old_log <- fread(log_file, na.strings = c("", ".", "NA"))
        # "unique() keeps reruns from adding duplicate rows for the same
        # site-year-tile combination."
        new_log <- unique(rbindlist(list(old_log, new_row), fill = TRUE))
    } else {
        new_log <- new_row
    }

    setorder(new_log, site, adm_year, tile_file, local_path)
    fwrite(new_log, log_file, na = "")
    invisible(new_log)
}

# Check whether the current LAADS token can access a known Black Marble file.
check_nasa_token <- function(bearer) {
    # "Request only the first bytes of a known file. This is a cheap token
    # check and avoids downloading a full H5 tile just to test authentication."
    token_check <- httr2::request(
        paste0(
            "https://ladsweb.modaps.eosdis.nasa.gov/",
            "archive/allData/5200/VNP46A4/2017/001/",
            "VNP46A4.A2017001.h21v09.002.2025105150816.h5"
        )
    ) |>
        httr2::req_headers(
            Authorization = paste("Bearer", bearer),
            Range = "bytes=0-1023"
        ) |>
        httr2::req_timeout(60) |>
        httr2::req_perform()

    if (grepl("text/html",
        token_check$headers[["content-type"]],
        ignore.case = TRUE
    ) &&
        grepl("Earthdata Login",
            httr2::resp_body_string(token_check),
            fixed = TRUE
        )) {
        stop(
            "LAADS_DAAC was rejected by NASA LAADS. ",
            "Refresh the token and accept the required ",
            "Earthdata EULAs before rerunning."
        )
    }
}

# Prepare the authenticated bearer token used across Black Marble downloads.
setup_blackmarble_downloads <- function(
  bearer = Sys.getenv("LAADS_DAAC"),
  check_token = TRUE
) {
    bearer <- normalize_laads_bearer(bearer)

    if (check_token) {
        check_nasa_token(bearer)
    }

    # "There is no namespace patching here. The returned bearer token is passed
    # into project-owned download functions below."
    bearer
}

# Build a buffered ROI polygon around one site-year of GPS points.
make_blackmarble_roi <- function(
  site_data,
  gps_cols = c("Longitude", "Latitude"),
  buffer_deg = 0.1
) {
    # "Build a small bounding box around all points for one site-year. This
    # tells the pipeline which tile(s) it needs, instead of downloading
    # globally."
    gps_cols <- validate_gps_cols(gps_cols)
    point_sf <- st_as_sf(as.data.frame(site_data),
        coords = gps_cols,
        crs = 4326,
        remove = FALSE
    )
    bbox <- st_bbox(point_sf)
    bbox["xmin"] <- bbox["xmin"] - buffer_deg
    bbox["xmax"] <- bbox["xmax"] + buffer_deg
    bbox["ymin"] <- bbox["ymin"] - buffer_deg
    bbox["ymax"] <- bbox["ymax"] + buffer_deg

    st_sf(geometry = st_as_sfc(bbox))
}

# Turn a date-like input into the annual year used by VNP46A4 products.
normalize_vnp46a4_year <- function(date) {
    # "VNP46A4 is annual in this workflow, so a year like 2019 is enough."
    year <- as.integer(format(as.IDate(paste0(date, "-01-01")), "%Y"))

    if (is.na(year)) {
        stop("Could not parse Black Marble year from date: ", date)
    }

    year
}

# Load the official Black Marble tile grid used to match ROIs to tile IDs.
read_blackmarble_tile_grid <- function() {
    # "This public grid maps Black Marble tile IDs like h17v07 to their
    # geographic footprints. We intersect it with the site ROI."
    sf::read_sf(
        paste0(
            "https://raw.githubusercontent.com/worldbank/",
            "blackmarbler/main/data/blackmarbletiles.geojson"
        ),
        quiet = TRUE
    )
}

# Read the annual Black Marble metadata CSV that lists available H5 tiles.
read_blackmarble_metadata <- function(
  year,
  bearer,
  product_id = "VNP46A4",
  timeout_seconds = 60
) {
    if (!identical(product_id, "VNP46A4")) {
        stop("This project workflow currently supports product_id = 'VNP46A4'.")
    }

    # "For annual VNP46A4, NASA stores the metadata CSV under day 001. The CSV
    # lists the available H5 tile filenames for that year."
    url <- paste0(
        "https://ladsweb.modaps.eosdis.nasa.gov/archive/allData/5200/",
        product_id, "/", year, "/001.csv"
    )

    response <- httr2::request(url) |>
        httr2::req_headers(Authorization = paste("Bearer", bearer)) |>
        httr2::req_timeout(timeout_seconds) |>
        httr2::req_perform()

    metadata <- readr::read_csv(
        I(rawToChar(httr2::resp_body_raw(response))),
        show_col_types = FALSE
    )
    metadata$year <- year
    metadata$day <- "001"
    as.data.table(metadata)
}

# Identify which Black Marble H5 tile files are needed for one ROI and year.
find_blackmarble_tile_files <- function(
  roi_sf,
  year,
  bearer,
  product_id = "VNP46A4"
) {
    tile_grid <- read_blackmarble_tile_grid()
    tile_grid <- tile_grid[!grepl("h00|v00", tile_grid$TileID), ]

    # "Prefer exact geometry intersection. If geometry validity causes trouble,
    # fall back to intersecting the ROI bounding box."
    intersects <- tryCatch(
        sf::st_intersects(tile_grid, roi_sf, sparse = FALSE),
        error = function(e) {
            roi_bbox_sf <- sf::st_as_sf(sf::st_as_sfc(sf::st_bbox(roi_sf)))
            sf::st_intersects(tile_grid, roi_bbox_sf, sparse = FALSE)
        }
    )

    needed_tiles <- tile_grid$TileID[rowSums(intersects) > 0]

    if (!length(needed_tiles)) {
        return(character())
    }

    metadata <- read_blackmarble_metadata(
        year = year,
        bearer = bearer,
        product_id = product_id
    )

    # "The metadata has full H5 filenames; each filename contains the tile ID."
    tile_pattern <- paste(needed_tiles, collapse = "|")
    trimws(basename(metadata$name[grepl(tile_pattern, metadata$name)]))
}

# Download one Black Marble H5 tile to the local cache with retries.
download_blackmarble_h5 <- function(
  file_name,
  bearer,
  h5_dir,
  timeout_seconds = 600,
  max_attempts = 5
) {
    # "The NASA archive URL is encoded in the official filename:
    # product/year/day/file_name."
    year <- substring(file_name, 10, 13)
    day <- substring(file_name, 14, 16)
    product_id <- substring(file_name, 1, 7)
    url <- paste0(
        "https://ladsweb.modaps.eosdis.nasa.gov/archive/allData/5200/",
        product_id, "/", year, "/", day, "/", file_name
    )

    file_name <- trimws(basename(file_name))
    h5_dir <- normalizePath(h5_dir, winslash = "/", mustWork = FALSE)

    if (grepl("[\r\n]", h5_dir) || grepl("[\r\n]", file_name)) {
        stop(
            "Black Marble cache path contains a hidden newline. ",
            "Check h5_dir and file_name."
        )
    }

    # "Keep the original NASA filename on disk. Site-specific meaning is logged
    # in blackmarble_download_log.csv instead of renaming the tile."
    download_path <- file.path(h5_dir, file_name)
    dir.create(dirname(download_path), recursive = TRUE, showWarnings = FALSE)

    if (!file.exists(download_path)) {
        response <- NULL
        attempts <- 0

        # "LAADS downloads can timeout on large files. Retry a few times before
        # failing the whole site-year."
        while (attempts < max_attempts) {
            attempts <- attempts + 1

            tryCatch(
                {
                    response <- httr2::request(url) |>
                        httr2::req_headers(
                            Authorization = paste("Bearer", bearer)
                        ) |>
                        httr2::req_timeout(timeout_seconds) |>
                        httr2::req_perform()
                    break
                },
                error = function(e) {
                    if (attempts < max_attempts) {
                        message(sprintf(
                            "Attempt %d failed: %s. Retrying in 2 seconds...",
                            attempts,
                            e$message
                        ))
                        Sys.sleep(2)
                    } else {
                        stop("All attempts failed. Error: ", e$message)
                    }
                }
            )
        }

        if (httr2::resp_status(response) != 200) {
            stop("Error downloading Black Marble tile: ", file_name)
        }

        writeBin(httr2::resp_body_raw(response), download_path)
    }

    download_path
}

# Replace Black Marble fill values with NA so they do not look like data.
remove_blackmarble_fill_value <- function(x, variable) {
    # "Black Marble uses sentinel values for missing data. For the annual
    # radiance variables used here, 65535 means no usable value."
    fill_65535 <- c(
        "DNB_At_Sensor_Radiance_500m",
        "DNB_BRDF-Corrected_NTL",
        "Gap_Filled_DNB_BRDF-Corrected_NTL",
        "AllAngle_Composite_Snow_Covered",
        "AllAngle_Composite_Snow_Covered_Num",
        "AllAngle_Composite_Snow_Free",
        "AllAngle_Composite_Snow_Free_Num",
        "NearNadir_Composite_Snow_Covered",
        "NearNadir_Composite_Snow_Covered_Num",
        "NearNadir_Composite_Snow_Free",
        "NearNadir_Composite_Snow_Free_Num",
        "OffNadir_Composite_Snow_Covered",
        "OffNadir_Composite_Snow_Covered_Num",
        "OffNadir_Composite_Snow_Free",
        "OffNadir_Composite_Snow_Free_Num",
        "AllAngle_Composite_Snow_Covered_Std",
        "AllAngle_Composite_Snow_Free_Std",
        "NearNadir_Composite_Snow_Covered_Std",
        "NearNadir_Composite_Snow_Free_Std",
        "OffNadir_Composite_Snow_Covered_Std",
        "OffNadir_Composite_Snow_Free_Std"
    )

    if (variable %in% fill_65535) {
        x[x == 65535] <- NA
    }

    x
}

# Convert one downloaded Black Marble H5 tile into a georeferenced raster.
blackmarble_h5_to_raster <- function(
  h5_file,
  variable = "NearNadir_Composite_Snow_Free",
  quality_flag_rm = NULL
) {
    h5_data <- terra::rast(h5_file)
    tile_id <- regmatches(
        basename(h5_file),
        regexpr("h[0-9]{2}v[0-9]{2}", basename(h5_file))
    )
    tile_grid <- read_blackmarble_tile_grid()
    tile_sf <- tile_grid[tile_grid$TileID %in% tile_id, ]

    if (!nrow(tile_sf)) {
        stop("Could not find Black Marble grid footprint for tile: ", tile_id)
    }

    if (!(variable %in% names(h5_data))) {
        stop(
            "'", variable, "' is not a valid H5 variable. Available variables include: ",
            paste(names(h5_data), collapse = ", ")
        )
    }

    raster <- h5_data[[variable]]

    if (length(quality_flag_rm) > 0) {
        # "For annual VNP46A4, quality layers are named from the selected
        # variable, for example NearNadir_Composite_Snow_Free_Quality."
        variable_short <- gsub("_Num|_Std", "", variable)
        quality_name <- paste0(variable_short, "_Quality")
        quality_raster <- h5_data[[quality_name]]

        for (value in quality_flag_rm) {
            raster[quality_raster == value] <- NA
        }
    }

    tile_bbox <- sf::st_bbox(tile_sf)
    terra::crs(raster) <- "EPSG:4326"
    terra::ext(raster) <- c(
        round(tile_bbox[["xmin"]]),
        round(tile_bbox[["xmax"]]),
        round(tile_bbox[["ymin"]]),
        round(tile_bbox[["ymax"]])
    )

    remove_blackmarble_fill_value(raster, variable)
}

# Build a site-year raster by finding, downloading, reading, and mosaicing tiles.
make_blackmarble_raster <- function(
  roi_sf,
  year,
  bearer,
  h5_dir,
  site,
  log_file,
  product_id = "VNP46A4",
  variable = "NearNadir_Composite_Snow_Free",
  quality_flag_rm = NULL
) {
    tile_files <- find_blackmarble_tile_files(
        roi_sf = roi_sf,
        year = year,
        bearer = bearer,
        product_id = product_id
    )

    if (!length(tile_files)) {
        warning("No Black Marble imagery exists for this site-year; returning NA.")
        return(NULL)
    }

    raster_list <- lapply(tile_files, function(tile_file) {
        local_path <- download_blackmarble_h5(
            file_name = tile_file,
            bearer = bearer,
            h5_dir = h5_dir
        )

        # "This runs whether the tile was downloaded now or reused from cache,
        # so the manifest describes actual tile usage by the current data run."
        append_blackmarble_manifest(
            site = site,
            adm_year = year,
            tile_file = tile_file,
            local_path = local_path,
            log_file = log_file
        )

        blackmarble_h5_to_raster(
            h5_file = local_path,
            variable = variable,
            quality_flag_rm = quality_flag_rm
        )
    })

    if (length(raster_list) == 1) {
        raster <- raster_list[[1]]
    } else {
        # "When an ROI crosses tile boundaries, combine the needed tiles before
        # cropping back to the site bounding box."
        raster <- do.call(terra::mosaic, c(raster_list, fun = "max"))
    }

    terra::crop(raster, roi_sf)
}

# Extract annual Black Marble values for all points in one site-year subset.
extract_site_year_degree_urban <- function(
  site_data,
  bearer,
  h5_dir = file.path("data", "raw", "blackmarble_h5"),
  log_file = file.path("data", "metadata", "blackmarble_download_log.csv"),
  gps_cols = c("Longitude", "Latitude"),
  buffer_deg = 0.1
) {
    gps_cols <- validate_gps_cols(gps_cols)
    roi_sf <- make_blackmarble_roi(
        site_data,
        gps_cols = gps_cols,
        buffer_deg = buffer_deg
    )
    year <- as.integer(site_data$adm_year[1])

    # "make_blackmarble_raster() is project-owned code, so installed package
    # namespaces are untouched."
    blackmarble_raster <- make_blackmarble_raster(
        roi_sf = roi_sf,
        year = year,
        bearer = bearer,
        h5_dir = h5_dir,
        site = site_data$site[1],
        log_file = log_file
    )

    if (is.null(blackmarble_raster)) {
        return(rep(NA_real_, nrow(site_data)))
    }

    # "terra::extract returns raster values at each GPS point; those values
    # become the degree_urban variable for this site-year."
    site_points <- terra::vect(
        as.data.frame(site_data[, ..gps_cols]),
        geom = gps_cols,
        crs = "EPSG:4326"
    )

    as.numeric(terra::extract(blackmarble_raster, site_points)[[2]])
}

# Add the degree_urban variable to a GPS dataset using site-year extraction.
add_blackmarble_degree_urban <- function(
  gps_data,
  bearer,
  h5_dir = file.path("data", "raw", "blackmarble_h5"),
  log_file = file.path("data", "metadata", "blackmarble_download_log.csv"),
  gps_cols = c("Longitude", "Latitude"),
  buffer_deg = 0.1
) {
    gps_cols <- validate_gps_cols(gps_cols)
    required_cols <- c("record_id", "site", gps_cols, "adm_date")
    missing_cols <- setdiff(required_cols, names(gps_data))

    if (length(missing_cols)) {
        stop(
            "Input data is missing required columns: ",
            paste(missing_cols, collapse = ", ")
        )
    }

    gps_data <- as.data.table(copy(gps_data))
    # "Use the year of adm_date because VNP46A4 is handled here as an annual
    # Black Marble product."
    gps_data[, adm_date := as.IDate(adm_date)]
    gps_data[, adm_year := as.integer(format(adm_date, "%Y"))]
    gps_data[, degree_urban := NA_real_]

    dir.create(h5_dir, recursive = TRUE, showWarnings = FALSE)
    dir.create(dirname(log_file), recursive = TRUE, showWarnings = FALSE)

    gps_extract <- gps_data[
        !is.na(get(gps_cols[1])) &
            !is.na(get(gps_cols[2])) &
            !is.na(adm_year)
    ]
    # "Process one site-year at a time so each download covers only the needed
    # points and the manifest can say which site-year used each tile."
    site_year_lookup <- unique(gps_extract[, .(site, adm_year)])

    if (nrow(site_year_lookup)) {
        for (i in seq_len(nrow(site_year_lookup))) {
            this_key <- site_year_lookup[i]
            this_site_year <- gps_extract[
                site == this_key$site &
                    adm_year == this_key$adm_year
            ]

            cat("Black Marble:", this_key$site, this_key$adm_year, "\n")

            # "Extract values for this site-year, then join them back to the
            # full data by record_id so rows with missing GPS remain in output."
            site_values <- data.table(
                record_id = this_site_year$record_id,
                degree_urban = extract_site_year_degree_urban(
                    this_site_year,
                    bearer = bearer,
                    h5_dir = h5_dir,
                    log_file = log_file,
                    gps_cols = gps_cols,
                    buffer_deg = buffer_deg
                )
            )
            gps_data[
                site_values,
                degree_urban := i.degree_urban,
                on = "record_id"
            ]
        }
    }

    gps_data[, adm_year := NULL]
    gps_data
}