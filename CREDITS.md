# Credits

## Mountain skyline profiles (`scripts/mtn_profiles.gd`)

360-degree horizon skylines raycast from real elevation data, baked into
`mtn_profiles.gd` by `~/bin/mtn_dem.py` + `~/bin/mtn_bake_profiles.py`.

- **Source data:** Mapzen/Tilezen Terrarium elevation tiles
  (`s3.amazonaws.com/elevation-tiles-prod`, AWS open-data mirror).
  The tiles aggregate public-domain DEM sources — SRTM (NASA, public
  domain), EU-DEM (Copernicus, free for any use with attribution), and
  national lidar (USGS 3DEP, public domain).
- **Derived work:** skyline elevation-angle profiles sampled at 0.5° azimuth
  steps from real valley viewpoints (Lake District, Bernese Oberland,
  Banff, Chamonix, Zermatt, Cortina d'Ampezzo, Grindelwald).
