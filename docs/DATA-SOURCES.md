# Data sources

AstroTool's built-in target catalog (217 Messier/NGC/IC/Sharpless objects,
`Sources/AstroCore/Sky/TargetCatalog.swift`) never touches the network — it
is a static, hand-curated table compiled into the app.

The **extended target catalog** (wave-5 Planning Workbench, Task 5) is an
**opt-in** feature (Settings ▸ Planning ▸ "Extended target catalog", off by
default) that downloads a much wider set of deep-sky objects from SIMBAD
and VizieR — the two catalogue/name-resolution services run by the
[CDS (Centre de Données astronomiques de Strasbourg)](https://cds.unistra.fr/)
— into a local cache. After the first download, Planning works entirely
offline: nothing here is ever queried from the planning render path itself,
only from the explicit "Update Catalog" action
(`Sources/AstroCore/Sky/CatalogFetcher.swift`, `CatalogCache.swift`).

## What a query sends

Only catalogue object names/coordinates are requested (e.g. "give me every
row of the Sharpless catalogue"). AstroTool never sends anything about the
user's own image library — no file path, file name, target name, note, or
FITS header ever leaves the machine through this feature.

## Attribution (required by CDS)

> This research has made use of the SIMBAD database and the VizieR
> catalogue access tool, CDS, Strasbourg, France.

This notice also appears in the app itself (Settings ▸ Planning ▸ Extended
target catalog).

## Catalogue identifiers and endpoints

All identifiers below were verified **live** against the production
services on **2026-08-15**. Five of the six sources use VizieR's classic
ASU-TSV interface; it uniformly exposes `_RAJ2000`/`_DEJ2000` (VizieR-
computed J2000 decimal-degree coordinates) for every catalogue regardless
of its original epoch or native coordinate format, so every VizieR source
below requests those two computed columns instead of parsing each
catalogue's own native RA/Dec representation.

| Source (`CatalogSource` case) | Catalogue | VizieR/SIMBAD identifier | Endpoint |
|---|---|---|---|
| `.ngcIC` | NGC 2000.0 (Sinnott, ed., 1988) — NGC/IC | `VII/118/ngc2000` | `https://vizier.cds.unistra.fr/viz-bin/asu-tsv` |
| `.sharpless` | Sharpless (Sh2) HII regions (Sharpless 1959) | `VII/20/catalog` | `https://vizier.cds.unistra.fr/viz-bin/asu-tsv` |
| `.lyndsBrightNebulae` | Lynds' Catalogue of Bright Nebulae (Lynds 1965) | `VII/9/catalog` | `https://vizier.cds.unistra.fr/viz-bin/asu-tsv` |
| `.vanDenBergh` | van den Bergh reflection nebulae (van den Bergh 1966) | `VII/21/catalog` | `https://vizier.cds.unistra.fr/viz-bin/asu-tsv` |
| `.barnard` | Barnard's Catalogue of 349 Dark Objects in the Sky | `VII/220A/barnard` | `https://vizier.cds.unistra.fr/viz-bin/asu-tsv` |
| `.abellPlanetaryNebulae` | Abell (1966) planetary nebulae, as SIMBAD's own `"PN A66 <n>"` identifiers | SIMBAD `ident`/`basic` tables, `id LIKE 'PN A66 %'` | `https://simbad.cds.unistra.fr/simbad/sim-tap/sync` |

Abell's 1966 planetary-nebula catalogue has no dedicated VizieR
machine-readable table; SIMBAD itself carries every one of those objects
under the catalogue's own numbering (`"PN A66 1"`, `"PN A66 2"`, ...), so
that one source queries SIMBAD's TAP service (ADQL) directly instead of
VizieR.

### Sample request (NGC/IC, VizieR ASU-TSV)

```
GET https://vizier.cds.unistra.fr/viz-bin/asu-tsv
    ?-source=VII/118/ngc2000
    &-out=Name,_RAJ2000,_DEJ2000,Type,size,mag
    &-out.max=999999
```

Sample response row (Rho Ophiuchi, IC 4604 — confirms the coordinate this
feature exists to fix a gap for):

```
Name    _RAJ2000  _DEJ2000  Type  size  mag
I4604   246.4004  -23.4333   Nb   60.0
```

(RA 246.4004°, Dec −23.4333° ≈ 16h25.6m, −23°26′ — the historic
Rho Ophiuchi position; the blank trailing field is a genuinely unrecorded
magnitude, not a parsing gap — `CatalogTarget.magnitude` stays `nil` for
this row.)

### Sample request (Lynds Bright Nebulae, VizieR ASU-TSV)

```
GET https://vizier.cds.unistra.fr/viz-bin/asu-tsv
    ?-source=VII/9/catalog
    &-out=Seq,_RAJ2000,_DEJ2000,Diam1
    &-out.max=999999
```

Sample response row (LBN 437, the other object the user named by hand):

```
Seq  _RAJ2000  _DEJ2000  Diam1
437  338.0510   40.5910     75
```

LBN's own running number (`Seq`, 1-1125) is the number amateurs write as
`"LBN <n>"` — not the catalogue's separate cross-reference `ID`/`Name`
columns.

### Sample request (Abell planetary nebulae, SIMBAD TAP/ADQL)

```
GET https://simbad.cds.unistra.fr/simbad/sim-tap/sync
    ?request=doQuery&lang=adql&format=json
    &query=SELECT id.id, b.ra, b.dec FROM ident id
           JOIN basic b ON id.oidref = b.oid
           WHERE id.id LIKE 'PN A66 %'
```

Sample response rows:

```json
{"data": [["PN A66    1", 3.229166666666667, 69.17333333333333],
          ["PN A66    2", 11.394491666666667, 57.9596888888889]]}
```

SIMBAD's own identifier is internally padded to a fixed width
(`"PN A66    1"`); `CatalogFetcher` collapses that to a single space
(`"PN A66 1"`) to match the plain-text designation shape every other
source in this file uses.

## Caching and merge behavior

- `CatalogCache` persists the last successful fetch under
  `~/Library/Application Support/AstroTool/Catalog/extended-catalog-v<N>.json`
  — a top-level directory, never nested inside a per-library folder and
  never inside the image library itself. A missing, corrupt, or
  version-mismatched cache file all fall back to `nil` (the built-in
  catalog stays in effect) rather than failing.
- `TargetCatalog.merged(builtIn:cached:)` merges the cache on top of the
  217 hand-verified built-in entries. On a duplicate designation, the
  built-in entry always wins — a fetched row can add coverage the built-in
  table doesn't have, never override a curated entry's coordinates or
  name.
