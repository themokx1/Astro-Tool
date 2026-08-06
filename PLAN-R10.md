# R10 — "A vizuális kör" + hiányzó funkciók terve

> Ez a dokumentum az R10-es fejlesztési kör munkaterve. A szakértői review
> (2026-08-06) megállapításaiból készült; a végrehajtás hullámokban, coding
> agentekkel történik. A kör végén ez a fájl törölhető vagy a CHANGELOG-ba
> olvad.

## Vezérelvek (minden taskra érvényes)

1. **Vasszabály változatlan**: a képkönyvtárban SOHA nem törlünk/mozgatunk.
   Minden lemez-írás kizárólag a `WriteGuard`-on át, `.astro_tool/` alá.
2. **Őszinte n/a**: hiányzó adatnál sosem tippelünk — magyarázó szöveg megy
   a szám helyére (a meglévő `notAvailableReason`-minta).
3. **TDD**: AstroCore-változás csak teszttel együtt (Tests/AstroCoreTests/).
   A teljes suite (`swift test`) zöld marad (jelenleg 847 teszt).
4. Kód-kommentek angolul, UI-szövegek magyarul — a meglévő stílust követve.
5. macOS 14 deployment target; Swift Charts használható (macOS 13+).
6. AstroCore-ba külső függőség és hálózati hívás NEM kerül. Hálózat
   (időjárás) kizárólag az app-rétegben, opt-in.

## A-hullám (core + visszajelzés-réteg) — párhuzamos

- **A1 `core-fits-renderer`** — `FITSImageRenderer` (FITS pixeladat → CGImage,
  debayer + MTF-autostretch). Új: `Sources/AstroCore/FITS/FITSImageRenderer.swift`.
- **A2 `core-sky-track`** — `Planner.altitudeTrack` / `moonAltitudeTrack` /
  `twilightMarkers` API-k a magasság-görbe charthoz.
- **A3 `core-nights`** — cross-target session-lekérdezés (`NightsQueries`):
  minden éjszaka egy listában minőség-adatokkal; CLI `astrotool nights`.
- **A4 `core-catalog`** — beágyazott célpont-katalógus (Messier 110 + fényes
  NGC/IC/Sh2) + `discover()` tervező-API a "Felfedezés" oldalhoz.
- **A5 `app-feedback`** — toast-réteg + IA-fixek (Audit "Szándékos" szegmens,
  Kereső sidebar-sor, Naptár kattintható célpontok, Minőség dátum-szűrő fix,
  Takarítás-oldal audit nélkül is).

## B-hullám (app-integrációk) — az A-hullám merge-e után

- **B1 `app-frame-review`** — FITS-thumbnail integráció + "Keret-átnéző"
  (blink) ablak billentyűs elfogad/elvet döntésekkel → `user_verdicts`
  (source `"app"`); a `stacklist` már tiszteletben tartja.
- **B2 `app-sky-chart`** — magasság-görbe chart (Ma este kijelölt sor +
  Célpont Áttekintés): célpont-ív, Hold-ív, szürkület-sávok, min-alt vonal.
- **B3 `app-nights-page`** — "Éjszakák" oldal (sidebar KÖNYVTÁR szekció):
  minden session cross-target táblában, minőség-oszlopokkal, szűrőkkel.
- **B4 `app-discovery-page`** — "Felfedezés" oldal: mit fotózzak ma este a
  katalógusból (FOV-illesztés a domináns setuphoz, "már gyűjtöd" jelölés).
- **B5 `app-trend-charts`** — kumulatív integráció chart (Áttekintés) +
  FWHM-idő trend chart (Minőség, session-re szűrve).
- **B6 `app-weather`** — opt-in Open-Meteo felhőzet-előrejelzés (Ma este
  tile + Naptár oszlop), default KI, cache, adatvédelmi megjegyzés.
- **B7 `app-affordance`** — ⋯ műveletgomb-oszlop a fő táblákhoz, fázis-
  legenda, tile/chip komponens-egységesítés, goal-editor egységesítés,
  Fogalomtár-link az ⓘ popoverből, Settings unsaved-changes jelzés +
  numerikus súly-mezők.
- **B8 `core-cli-parity`** — per-filter integráció-bontás (core + Áttekintés
  kártya) + CLI-paritás: `ack`, `note`, `goal`, `search --all`, `night-info`.

## Merge-rend

Minden agent saját worktree-ben dolgozik és commitol; a hullám végén a fő
session mergeli a mainre, teljes `swift test` után pushol. Konfliktus esetén
a main állapota a mérvadó, az agent-változást kell adaptálni.
