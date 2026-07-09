library(data.table)
library(here)

if (!requireNamespace("rhdx", quietly = TRUE)) {
    stop(
        "The rhdx package is required. Install it with:\n",
        "remotes::install_github('dickoa/rhdx')"
    )
}

boundary_dir <- here("data", "raw", "boundaries", "hdx_admin_boundaries")
manifest_file <- file.path(boundary_dir, "hdx_admin_boundaries_manifest.csv")

boundary_targets <- list(
    list(
        country = "Kenya",
        iso3 = "ken",
        sites = c("Migori", "Nairobi", "Kilifi"),
        hdx_dataset_names = c("cod-ab-ken"),
        search_query = "Kenya administrative boundaries COD AB shapefile"
    ),
    list(
        country = "Uganda",
        iso3 = "uga",
        sites = "Kampala",
        hdx_dataset_names = c("cod-ab-uga"),
        search_query = "Uganda administrative boundaries COD AB shapefile"
    ),
    list(
        country = "Malawi",
        iso3 = "mwi",
        sites = "Blantyre",
        hdx_dataset_names = c("cod-ab-mwi"),
        search_query = "Malawi administrative boundaries COD AB shapefile"
    ),
    list(
        country = "Burkina Faso",
        iso3 = "bfa",
        sites = "Banfora",
        hdx_dataset_names = c("cod-ab-bfa"),
        search_query = "Burkina Faso administrative boundaries COD AB shapefile"
    ),
    list(
        country = "Pakistan",
        iso3 = "pak",
        sites = "Karachi",
        hdx_dataset_names = c("cod-ab-pak"),
        search_query = "Pakistan administrative boundaries COD AB shapefile"
    ),
    list(
        country = "Bangladesh",
        iso3 = "bgd",
        sites = c("Dhaka", "Matlab"),
        hdx_dataset_names = c("cod-ab-bgd"),
        search_query = "Bangladesh administrative boundaries COD AB shapefile"
    )
)

`%||%` <- function(x, y) {
    if (is.null(x) || !length(x) || all(is.na(x))) {
        return(y)
    }

    x[1]
}

clean_filename <- function(x) {
    x <- gsub("\\?.*$", "", x)
    x <- basename(x)
    x <- gsub("[^A-Za-z0-9._-]+", "_", x)
    x
}

as_resource_table <- function(resources) {
    if (!length(resources)) {
        return(data.table())
    }

    rbindlist(lapply(resources, function(resource) {
        x <- as.list(resource)
        data.table(
            resource_id = x$id %||% NA_character_,
            resource_name = x$name %||% NA_character_,
            resource_format = tolower(x$format %||% NA_character_),
            resource_url = x$url %||% NA_character_,
            resource_description = x$description %||% NA_character_,
            resource = list(resource)
        )
    }), fill = TRUE)
}

is_shapefile_boundary_resource <- function(resource_table) {
    text <- paste(
        resource_table$resource_name,
        resource_table$resource_description,
        resource_table$resource_url
    )
    spatial_format <- resource_table$resource_format %in% c(
        "shp", "zipped shapefile"
    )
    spatial_url <- grepl(
        "(\\.shp\\.zip|\\.shp)(\\?|$)",
        resource_table$resource_url,
        ignore.case = TRUE
    )
    boundary_name <- grepl(
        "admin|adm[0-9]|boundary|boundaries|shapefile|cod",
        text,
        ignore.case = TRUE
    )

    (spatial_format | spatial_url) & boundary_name
}

dataset_date_end <- function(dataset) {
    dates <- tryCatch(rhdx::get_dataset_date(dataset), error = function(e) NA)
    dates <- as.Date(dates)
    if (all(is.na(dates))) {
        return(as.Date(NA))
    }

    max(dates, na.rm = TRUE)
}

dataset_has_boundaries <- function(dataset) {
    resources <- rhdx::get_resources(dataset)
    resource_table <- as_resource_table(resources)
    nrow(resource_table) && any(is_shapefile_boundary_resource(resource_table))
}

pull_target_dataset <- function(target) {
    for (dataset_name in target$hdx_dataset_names) {
        dataset <- tryCatch(
            rhdx::pull_dataset(dataset_name),
            error = function(e) NULL
        )
        if (!is.null(dataset) && dataset_has_boundaries(dataset)) {
            return(dataset)
        }
    }

    datasets <- rhdx::search_datasets(target$search_query, rows = 10L)
    if (!length(datasets)) {
        stop("No HDX datasets found for ", target$country)
    }

    dataset_scores <- rbindlist(lapply(seq_along(datasets), function(i) {
        dataset <- datasets[[i]]
        title <- dataset$data$title %||% ""
        name <- dataset$data$name %||% ""
        resources <- rhdx::get_resources(dataset)
        resource_table <- as_resource_table(resources)
        has_boundaries <- nrow(resource_table) &&
            any(is_shapefile_boundary_resource(resource_table))
        title_score <- grepl("common operational|cod|administrative", title,
            ignore.case = TRUE
        )
        name_score <- grepl("cod|admin", name, ignore.case = TRUE)

        data.table(
            index = i,
            score = as.integer(has_boundaries) * 10L +
                as.integer(title_score) * 2L +
                as.integer(name_score),
            dataset_end = dataset_date_end(dataset)
        )
    }), fill = TRUE)

    dataset_scores <- dataset_scores[score > 0]
    if (!nrow(dataset_scores)) {
        stop("No shapefile boundary-like HDX datasets found for ", target$country)
    }

    setorder(dataset_scores, -score, -dataset_end)
    datasets[[dataset_scores$index[1]]]
}

download_target_boundaries <- function(target, unzip_archives = TRUE) {
    country_dir <- file.path(boundary_dir, target$iso3)
    dir.create(country_dir, recursive = TRUE, showWarnings = FALSE)

    dataset <- pull_target_dataset(target)
    resources <- rhdx::get_resources(dataset)
    resource_table <- as_resource_table(resources)
    resource_table <- resource_table[is_shapefile_boundary_resource(resource_table)]

    if (!nrow(resource_table)) {
        stop("No shapefile boundary resources found for ", target$country)
    }

    resource_table[, local_file := mapply(function(url, id) {
        filename <- clean_filename(url)
        if (!nzchar(filename) || is.na(filename)) {
            filename <- paste0(id, ".zip")
        }
        file.path(country_dir, filename)
    }, resource_url, resource_id, USE.NAMES = FALSE)]

    for (i in seq_len(nrow(resource_table))) {
        rhdx::download_resource(
            resource_table$resource[[i]],
            folder = country_dir,
            filename = basename(resource_table$local_file[i]),
            force = FALSE,
            quiet = FALSE
        )

        if (unzip_archives &&
            grepl("\\.zip$", resource_table$local_file[i], ignore.case = TRUE)) {
            unzip_dir <- file.path(
                country_dir,
                tools::file_path_sans_ext(basename(resource_table$local_file[i]))
            )
            dir.create(unzip_dir, recursive = TRUE, showWarnings = FALSE)
            unzip(resource_table$local_file[i], exdir = unzip_dir)
        }
    }

    resource_table[, `:=`(
        country = target$country,
        iso3 = target$iso3,
        sites = paste(target$sites, collapse = "; "),
        dataset_name = dataset$data$name %||% NA_character_,
        dataset_title = dataset$data$title %||% NA_character_,
        dataset_date_end = dataset_date_end(dataset),
        downloaded_at = Sys.time(),
        resource = NULL
    )]

    setcolorder(resource_table, c(
        "country", "iso3", "sites", "dataset_name", "dataset_title",
        "dataset_date_end", "resource_id", "resource_name",
        "resource_format", "resource_url", "local_file", "downloaded_at",
        "resource_description"
    ))

    resource_table[]
}

rhdx::set_rhdx_config(hdx_site = "prod")
dir.create(boundary_dir, recursive = TRUE, showWarnings = FALSE)

manifest <- rbindlist(
    lapply(boundary_targets, download_target_boundaries),
    fill = TRUE
)
fwrite(manifest, manifest_file)

cat("Downloaded HDX administrative boundary resources to:", boundary_dir, "\n")
cat("Wrote manifest to:", manifest_file, "\n")
