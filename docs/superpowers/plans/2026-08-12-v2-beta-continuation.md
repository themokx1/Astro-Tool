# AstroTool V2 Beta folytatási állapot

## Aktuális állapot

- Branch: `codex/v2.0.0-ui-rework`
- Legutóbbi commit: `5f4feda feat: aggregate V2 nights across projects`
- Kiadott prerelease: `v2.0.0-beta.1`
- Telepített app: `/Applications/AstroTool.app` (2.0.0, build 20001)
- A `v2.0.0-beta.1` tag a `de2e276` állapotot jelöli; a későbbi projektmentés
  és Nights aggregáció a következő `v2.0.0-beta.2` kiadásba kerüljön.
- A felhasználó képkönyvtárát tilos módosítani, mozgatni vagy törölni.

## Elkészült V2 részek

- Natív Home, Projects, Nights, Planning, Library és Insights munkatér.
- Read-only onboarding és könyvtárscan.
- App-owned SQLite metadata, stabil UUID-k és lineage.
- Offline magyar/angol/katalógusszámos célpontkeresés.
- Valódi, duplikációbiztos projektmentés és projektlista.
- `NightsQuery`, amely egy éjszakába több projektet és Series rekordot aggregál.
- A legutóbbi teljes kiadási ellenőrzés: 1714 teszt / 28 suite PASS; ez a
  projektmentés és Nights commitok előtt futott, ezért új teljes futás szükséges.

## Következő végrehajtási sorrend

1. TDD-vel készíts `NightsStore`-t a `NightsQuery` köré, ugyanazzal a production
   és izolált UI-fixture metadata factory mintával, mint a `ProjectsStore`.
2. Kösd a store-t a `V2RootView` scan-summary életciklusához, majd jeleníts valódi
   éjszaka-listát a `NightsView`-ban: dátum, projektek, sorozatok, expozíciók,
   filter és összes integráció. Üres adatnál őszinte állapot maradjon.
3. Implementáld a terv Task 4 `NightRibbonModel` részét AstroCore idővonal-adatokkal,
   külön akadálymentes szöveges összegzéssel.
4. Futtasd a fókuszált teszteket, teljes `swift test --disable-sandbox --no-parallel`
   suite-ot és az AstroToolApp buildet.
5. Minden zöld vertikális szelet után külön commit és push.
6. Készíts `2.0.0 Beta 2` release note-ot, Universal buildet, telepítsd, ellenőrizd,
   majd `v2.0.0-beta.2` GitHub prerelease-t.

## Folytató prompt

Folytasd az AstroTool V2 béta implementációját a
`codex/v2.0.0-ui-rework` branchen a
`docs/superpowers/plans/2026-08-12-v2-beta-continuation.md` alapján. Használd a
meglévő V2 design- és workflow-parity terveket, dolgozz szigorú TDD-vel, minden
zöld vertikális szelet után commitolj és pusholj. Elsőként kösd a már elkészült
`NightsQuery`-t egy `NightsStore`-on keresztül a valódi `NightsView` listához,
majd készítsd el a Night Ribbont. Soha ne módosítsd a felhasználó képkönyvtárát.
A következő kiadás legyen `v2.0.0-beta.2`, Universal, tesztelt és telepített.
