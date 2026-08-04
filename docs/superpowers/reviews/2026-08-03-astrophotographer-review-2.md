# Asztrofotós szakértői review — 2. kör (R7)

**Dátum:** 2026-08-03
**Jelleg:** szakértői termék-review, valós DB-n mért adatokkal

---

## Ground truth measured first (read-only, on the real volume)

| quantity | measured value | how |
|---|---|---|
| EGAIN, ASI2600MC @ gain 100 / offset 50 | **0.242863 e⁻/ADU** | `fits_meta.egain`, identical on all 2600 frames |
| bias pedestal | **501 ADU** (p1 490 / p99 513) | median of a real `Bias_…gain100_…fit` |
| **read noise** | **1.30 e⁻** | σ of a bias-*pair difference* / √2 × EGAIN (datasheet ~1.5; the pair-difference value is the correct *temporal* RN). MAD gave 1.02 — too low, ADU quantization ≈ 4 e⁻/ADU⁻¹; use clipped σ, not MAD |
| dark current @ −10 °C | **< 0.004 e⁻/s/px** (below 1-ADU quantization: 60 s dark median = 501 = bias exactly) | real `Dark_…-10.0C_60s` |
| per-Bayer sky, Rosette 293 mm 120 s | R 14 / G 8–9 / B **5** ADU above bias | central-crop per-parity medians |
| per-Bayer sky, NGC7000 179 mm 120 s | R 42 / G 69–70 / B 40 ADU | ditto |
| `ratings` star metrics | **fwhm / roundness / star_count 100% NULL on all 586 rows**; `siril_version = "Siril is started as macOS application"` | DB |
| user's real stacking pipeline | **DeepSkyStacker** (`lights.dssfilelist`, 4 files) + **Sirilic** (`sirilic.ssf`, 3) + LightFrameRater triage | files table |
| DSS side-products | **346 `.info.txt`** with `Quality`, `SkyBackground`, `NrStars`, `MeanRadius`, `Circularity`, per-star `Axises` | real file read |

### ⛔ Blocker found in shipped code
`SessionQuality.swift:163` — `background * egain / exptime / (scale*scale)` never subtracts the bias pedestal. Rosette: reports **0.147** e⁻/s/arcsec², truth **0.0023** → **~64× inflated**. Every `quality`/`health`/export number in electron units since 0.4.0 is wrong. Nothing in candidates 1–2 can be built on top of this until fixed.

---

## Verdicts

### 1. Sub-exposure optimizer — **SHIP, heavily MODIFIED**
Correct swamping derivation (read noise adds fraction *C* to per-sub noise):
√(R²+B·t) = (1+C)·√(B·t) → **t = R² / (B·((1+C)²−1))**, where `B = sky_rate + dark_rate` [e⁻/s/px].
- **C = 5% default** → t = R²/0.1025·B = 9.76·R²/B. This *is* Glover's "sky ≥ 10·RN²" rule (9.76 ≈ 10) — quote both. Show C=10% (4.76·R²/B) as the "short subs" column.
- **Sky must be per-Bayer-channel, and the recommendation must use the WEAKEST channel** (B here) — that is the read-noise-limited one. `NativeStats` currently returns one channel-mixed median; add 4 medians via `(row%2, col%2)` in the same pass (free). The mixed median ≈ G by construction (G is 50% of pixels), so B is *not* recoverable from it — this is why the per-channel change is mandatory, not cosmetic.
- **sky_rate = (median_ch − bias_level) × EGAIN / EXPTIME.** `bias_level` measured from real Bias frames per `(camera, gain, offset)`, cached in DB; **refuse to output a number if absent — never guess.**
- **Read noise: measure it, no camera table.** σ(bias₁−bias₂)/√2 × EGAIN, 5σ-clipped, central crop. Verified: 1.30 e⁻. Works for any camera that has ≥2 bias FITS + EGAIN. Config override allowed, no hardcoded model list.
- **Canon R8: no EGAIN, no bias FITS → feature is ASI-only.** Say so, don't extrapolate.
- **Cap the answer.** Real output on the user's data:

| session | weakest ch | sky e⁻/s/px | t(C=5%) | t(C=10%) | shot | read share of per-sub noise @120 s |
|---|---|---|---|---|---|---|
| NGC7000 179 mm | B | 0.081 | **196 s** | 96 s | 120 s | 8.1% (G: 4.8%) |
| Rosette 293 mm | B | 0.0101 | **1257 s** | 613 s | 120 s | 44.0% (G: 31.7%) |

The Rosette answer (21 min) is mathematically right and operationally insane → cap with `expose.maxSubSeconds` (default 300) **and** a measured saturation cap from the existing `ratings.saturated_fraction`, and phrase the capped case as "read noise is not your limiting factor here" rather than printing 1257 s.
- HU: `NGC 7000 · 179 mm: a mért égháttér mellett 200 s az ideális szub (most 120 s — a leolvasási zaj a keret zajának 8%-a, ez már rendben van).`
- HU (capped): `Rosette · 293 mm: nagyon sötét az égháttér, a leolvasási zaj a kék csatorna zajának 44%-a — 300 s-ig érdemes hosszabbítani (elméletileg 21 min, de guiding/műhold miatt nem javasolt).`
- **Effort: M** (after the sensor-characterization prerequisite).

### 2. "Is it enough?" SNR advisor — **MODIFY: merge into #1, and drop the absolute claim**
√t is exact in the sky-limited regime and **needs no measured sky at all** — so a measured-sky "honest normalization" is a red herring. The two honest outputs:
- relative multiplier `√(t_new/t_old)` labelled **relatív SNR**, never "SNR";
- the genuinely useful invariant: **hours needed for the next +10% = 0.21·t** (next +5% = 0.1025·t). Verified: 10 h → 2.1 h; 20 h → 4.2 h; 30 h → 6.3 h.

Guards that make it honest, all of which the tool can enforce: count only **same setup fingerprint** (signal/px differs between 302 mm and 70 mm — cross-setup addition is meaningless), only **usable** frames (post-`FrameSet` dedup + Reject exclusion), and state the "same conditions" assumption. **Reject any absolute "elég van már" verdict** — that needs target surface brightness, which we do not have. The only honest absolute is the per-sub read-noise share from #1.
- HU: `M84 · 6,2 h van meg: +3 h → relatív SNR ×1,21. A következő +10%-hoz 1,3 h kell, utána már 2,9 h — innen lassul.`
- **Effort: S** as a section of #1.

### 3. Night report card — **SHIP**
It is pure composition of shipped commands (timeline, quality, health, calib, panels, notes) → the value is the post-night ritual, not new math. What we'd forget, and what's genuinely pro:
- **Altitude/airmass track of the session** from `DATE-OBS` × target coords × site: min/median/max altitude, airmass span, and *how many minutes were shot below 30°*. This explains a bad night better than FWHM alone and is not in the tool today.
- **Actual Moon separation and Moon altitude during the session** (we compute it only for *future* planning).
- **Per-sub noise breakdown from #1** (read share, sky e⁻/s/arcsec² — after the 64× fix).
- **DSS/LightFrameRater reject-reason histogram** (`cloud-or-haze-loss`, `tracking-issue`, …) — the user's own verdicts, currently invisible to the tool.
- **This session's calib verdict**: were the linked darks gain/offset/temp-matched, was there a flat, rotator delta.
- One `todos` block. Write additively to `.astro_tool/reports/<target>-<date>.html` via `WriteGuard`.
- HU: `Éjszaka-riport kész: 3 h 42 m ablak, 59% hatékonyság, 2 h 11 m használható; a keretek 22%-a 30° alatt készült; Hold 38%, 71°-ra.`
- **Effort: M**

### 4. Best-frame stack list export — **MODIFY (mechanism and source both wrong as specced)**
Two corrections:
- **Source:** `ratings` has **zero** star metrics (all NULL) and covers 586 of 2264 frames. A "best-frame" list from it today would rank on background+saturation only. The selection must come from **DSS `Quality`/`NrStars`/`MeanRadius` (346 frames) + the user's LightFrameRater triage folders + existing `Stack/` picks**, with our score as a tiebreaker.
- **Mechanism:** Siril 1.4 has **no "stack this text list" command**. `.lst` is not a Siril stacking input. `select`/`unselect` operate on *sequence indices*, which depend on `convert` ordering → fragile, do not generate those. The mechanisms that actually work:
  1. **Hardlink directory** (what LightFrameRater does, and iron-rule-safe): `.astro_tool/stacklists/<target>-<date>-<tag>/` + a generated `.ssf` that does `cd` → `convert light -out=.` → `calibrate` → `register` → `stack`. Robust, and the *only* one that works for both Siril and Sirilic.
  2. **`.dssfilelist`** — the user already has 4 of these; format confirmed: line 1 `DSS file list`, line 2 `CHECKED\tTYPE\tFILE`, then `1|0 \t light \t <path relative to the list's own directory>`. Emitting this with our picks as `1` and rejects as `0` drops straight into DeepSkyStacker, which is demonstrably half of the user's workflow. **Highest actual utility, near-zero effort.**
- Default: emit both (hardlink dir + `.dssfilelist` + `.ssf`), never write into `sessions/`.
- HU: `118 keretből 94 kiválasztva (Q ≥ medián, FWHM ≤ 1,25× medián) → .astro_tool/stacklists/M84-2026-04-18/ + lights.dssfilelist (DSS-be közvetlenül betölthető).`
- **Effort: S/M**

### 5. Moon calendar month planner — **SHIP, but as `plan --month`, not a new module**
`SunMoon.astronomicalTwilight(nightOf:)`, `moonIlluminationPercent`, `angularSeparationDeg` and `Planner.plan(referenceDate:)` all exist → a 30-iteration loop plus a compact grid. Worth it *because* the nightly plan structurally cannot answer "which weekend do I take off work for". Content per night: astro-dark hours, Moon illumination + rise/set, and per-target the **overlap minutes of (target > min-alt) ∩ (astro dark) ∩ (Moon separation OK)** — that overlap number, not the Moon phase, is the decision variable.
- HU: `Aug. 12–15: 5,8 h csillagászati sötétség, Hold 6% — M31-re 4,2 h használható ablak. Aug. 26–29: Hold 92%, csak szűrős célpont.`
- **Effort: S**

### 6. Dust watch — **SKIP** (would ship a flaky feature)
The real data kills it: 10 ASI flat sets over 8 months at **7 different focal lengths** (133/134/179/293/298.8/300/302/387 mm), rotator angle varying across sessions (178°/231°/355°/356° from filenames), and **`FILTER` is empty on every flat**. Mote diameter scales with f-ratio and defocus, and anything upstream of the rotator rotates → cross-session spot maps are not comparable. Comparable pairs in the whole archive: **2–3**. Expected output is false positives.
- Cheap honest replacement if something must ship here: within a *matched* group only (`|Δfocallen| ≤ 1%` **and** `|Δrotator| ≤ 5°` **and** same fingerprint), report the flat's **vignetting profile** (corner/center ratio) and the count of >3% local dips — and phrase it as "changed / unchanged", never "new dust at (x,y)". Fold into the existing calib-health block.
- HU: `Flat-profil: sarok/közép 0,71 (előző, ugyanezzel a setuppal: 0,73) — érdemi változás nincs.`
- **Effort: S** as a calib-health addition; **L and unreliable** as specced.

---

## Two candidates you didn't list that beat half of the list

**A. Ingest the DSS `.info.txt` + `.dssfilelist` files (M).** 346 `.info.txt` files already sitting in the archive contain `Quality`, `NrStars`, `MeanRadius` (FWHM proxy), `Circularity`, `SkyBackground` and per-star `Axises` (→ elongation) — i.e. exactly the star metrics our Siril path fails to produce (100% NULL, 586/2264 coverage). Plus the `.dssfilelist` `CHECKED` column is **the user's own accept/reject decision, machine-readable**. Read-only parse, no new dependency, no Siril. This single item un-breaks the Quality tab, the rate z-scores, and candidate 4 — and it should land *before* anything that consumes ratings.
- HU: `346 DSS mérés beolvasva (Quality, csillagszám, MeanRadius) — a Minőség fül végre csillagmetrikát is mutat.`

**B. `astrotool sensor` — measured sensor characterization (M).** Per `(camera, gain, offset)`: bias level, read noise from bias-pair difference, dark rate per CCD-TEMP bucket, EGAIN, and drift warnings ("offset changed 50→30 between sessions → your master bias no longer matches"). This is the prerequisite for #1/#2, it validates the existing calib matcher against *measured* levels instead of filename parsing, and it is a genuinely advanced feature no library manager offers.
- HU: `ASI2600MC · gain 100 · offset 50: bias 501 ADU, leolvasási zaj 1,30 e⁻ (mérve), dark −10 °C-on < 0,004 e⁻/s — a gyári 1,5 e⁻ helyett a valós érték.`

*Also flag as a bug, not a feature:* `SirilCLI` writes `siril_version = "Siril is started as macOS application"` and parses zero stars — the Siril adapter is silently non-functional on this machine.

---

## Build order

1. **Fix `SessionQuality` bias-pedestal bug (64×) + per-Bayer medians in `NativeStats` + `astrotool sensor`** (B). — M. Everything electron-domain is wrong until this lands; DB additive: `sensor_profile(camera,gain,offset)`, `ratings.bg_r/bg_g/bg_b`.
2. **DSS ingest** (A: `.info.txt` + `.dssfilelist`). — M. Un-breaks ratings; unblocks 4 and the report card's reject histogram.
3. **`astrotool expose` = candidates 1 + 2 merged.** — M. t = R²/(B·((1+C)²−1)), C=5% default, weakest Bayer channel, capped, plus the 0.21·t marginal-SNR line. Refuses to print numbers where bias level or EGAIN is missing (Canon).
4. **`astrotool stacklist`** (candidate 4, modified). — S/M. Hardlink dir + `.dssfilelist` + `.ssf`; no `select`/`unselect` index games.
5. **`astrotool report`** (candidate 3) with altitude/airmass track, achieved Moon geometry, per-sub noise breakdown, reject histogram. — M. **Rider (½ day): `plan --month`** (candidate 5) — it's a loop over existing functions, ship it alongside.

**Not in the order:** dust watch (SKIP; optionally the S-sized vignetting-profile line inside calib health).
