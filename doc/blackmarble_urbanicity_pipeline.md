# Black Marble urbanicity pipeline

This project is organized for RStudio users.

## What users need first

### 1. NASA Earthdata / LAADS token

Black Marble H5 files come from NASA LAADS DAAC. Users need a NASA Earthdata account and a LAADS bearer token.

Use the BlackMarbleR token instructions:

https://worldbank.github.io/blackmarbler/#bearer-token

Short version:

1. Create or sign in to a NASA Earthdata account.
2. Fill in the required profile fields such as study area, user type, and organization.
3. Accept the required EULAs.
4. Authorize LAADS access if prompted.
5. In Earthdata Login, use Generate Token / Show Token and copy the bearer token.

### 2. Save the token in `.Renviron`

In the RStudio Console, run:

```r
install.packages("usethis")
usethis::edit_r_environ()
```

Add this line to `.Renviron`:

```text
LAADS_DAAC=PASTE_YOUR_TOKEN_HERE
```

Do not include quotes. Do not include the word `Bearer`.

Save `.Renviron`, then restart RStudio with:

```text
Session > Restart R
```

Check that RStudio can see the token:

```r
Sys.getenv("LAADS_DAAC")
```

If this returns `""`, the file was not saved in the right place or RStudio was not restarted.

## The one script to edit

Users usually only edit:

```text
R/process_blackmarble_urbanicity.R
```

For real data, change these lines near the top:

```r
input_file <- file.path("data", "my_real_gps_data.csv")
output_file <- file.path("data", "processed", "my_real_gps_data_urbanicity.csv")
gps_cols <- c("Longitude", "Latitude")
```

If coordinate columns have different names, use the real names:

```r
gps_cols <- c("lon", "lat")
```

The first value in `gps_cols` must be longitude and the second must be latitude.

Then click Source in RStudio to run `R/process_blackmarble_urbanicity.R`.

## Required input columns by default

```text
record_id, site, Longitude, Latitude, adm_date
```

With custom coordinate columns, the required columns are:

```text
record_id, site, adm_date, plus the two columns named in gps_cols
```

## Teaching data

For teaching or testing, source this script first:

```text
R/simulate_chain_gps_data.R
```

This writes:

```text
data/simulated_chain_gps_data.csv
```

Then source:

```text
R/process_blackmarble_urbanicity.R
```

Outputs:

```text
data/processed/simulated_chain_gps_data_urbanicity.csv
data/metadata/blackmarble_download_log.csv
```

## Optional map check

The BlackMarbleR documentation shows a map example with `geom_spatraster()`. In this project, use:

```text
R/plot_blackmarble_site_map.R
```

Run `R/process_blackmarble_urbanicity.R` first, then open `R/plot_blackmarble_site_map.R` in RStudio and edit:

```r
site_name <- "Banfora"
target_year <- 2016
gps_cols <- c("Longitude", "Latitude")
```

Click Source. The script uses the H5 files already listed in `data/metadata/blackmarble_download_log.csv`, log-scales the raster for display, overlays the site points, and writes a PNG map to `data/processed/`.
## File layout

```text
data/
  simulated_chain_gps_data.csv
  raw/
    blackmarble_h5/
      VNP46A4.A2016001.h17v07.002.2025101113454.h5
  processed/
    simulated_chain_gps_data_urbanicity.csv
  metadata/
    blackmarble_download_log.csv
```

The H5 files keep their original NASA filenames because the file identity is the tile/date/product. Site-specific usage is tracked in `blackmarble_download_log.csv` with:

```text
site,adm_year,tile_file,local_path
```