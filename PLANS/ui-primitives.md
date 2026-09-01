# UI-primitiivit: ikkunat ja valikot Admiral-ohjelmista

Tila: ehdotus (2026-08-30). Tausta: `PLANS/c64os-feasibility.md` luvut 9–10 ja
`xcb3-ext/libs/lib_ui.bas`-analyysi. Malli: *puskuroidut ikkunat + omistajakartta + write-through* — jokainen
ikkuna on `W*H`-merkkipuskuri, 1000 tavun kartta kertoo kunkin ruutusolun
päällimmäisen ikkunan, ja `put_char` kirjoittaa ruutuun heti jos solu on
kirjoittavan ikkunan oma. `REFRESH` rakentaa kartan ja blittaa kaiken vain
kun ikkunajoukko muuttuu. Ei hiirtä.

Historia: v1 clip-rect + `BOX/SCRGET/SCRPUT`, v2 taustantallennus
(lib_ui-malli, LIFO-rajoite), v3 puskurit + refresh-politiikka, v4 tämä. Ks. `c64os-feasibility.md`.

## 1. Malli

- `WINDOWS` on globaali lista (GC-juuri) = z-järjestys, viimeinen päällimmäisenä.
- Ikkuna on tavallinen dict:
  ```
  <"X": x, "Y": y, "W": w, "H": h, "T": title|NONE, "COL": väri,
   "BUF": <str, W*H screen codea>, "R": kursoririvi, "C": kursorisarake,>
  ```
  Puskuri on pelkkä sisus (ilman reunusta). Reunus ja otsikko piirretään
  vasta refreshissä, joten ne eivät vie puskuritilaa. Yksi väri per ikkuna;
  reverse = bitti 7 puskurissa.
- `MAP` on kernelin omistama 1000 tavun string heapissa (GC-juuri): solun
  päällimmäisen ikkunan indeksi `WINDOWS`-listassa. Rakennetaan
  `REFRESH`issä ikkunat z-järjestyksessä täyttäen.
- **Write-through:** `put_char` kirjoittaa puskuriin ja, jos
  `MAP[solu] == nykyinen ikkuna`, saman tavun `$0400`:aan. `$0400` on aina
  RAMia → ei `$01`-vaihtoa per merkki. Väri (`$D800`) kirjoitetaan vain
  refreshissä (per ikkuna vakio). Tuloste näkyy reaaliajassa, myös
  osittain peitetyssä ikkunassa oikein.
- Vieritys: puskurin memmove + omistettujen solujen blit (W*H vertailua).
- Kursori näytetään vain, jos sen solu on nykyisen ikkunan oma.
- Kernelin nykyinen suora ruutupolku (`screen_put_char`, `scr_newline`,
  `screen_scroll_up`) **korvataan** puskuriversiolla (stride W, kursori
  dictissä) — ei rinnakkaista toteutusta.

## 2. Kernel-builtinit

| Kutsu | Semantiikka | Arvio |
|---|---|---|
| `P = WINDOW(X, Y, W, H [, TITLE])` | Luo dictin ja `W*H`-puskurin (tyhjä), lisää `WINDOWS`-listan loppuun (päällimmäiseksi), tekee siitä nykyisen. Ikkunan on mahduttava ruudulle (ei leikkausta refreshissä). | ~150 t |
| `CLOSE(P)` | Poistaa listasta. Jos P oli nykyinen, nykyiseksi tulee `ROOT`. | ~60 t |
| `USE(P) -> Q` | Tee P:stä `PRINT`/`INPUT`-kohde; palauttaa edellisen. | ~50 t |
| `AT(P, X, Y)` | Kursori P:n sisäiseen kohtaan. | ~30 t |
| `ATTR(P, X, Y, W, F)` | W merkin reverse päälle (`F=1`) / pois (`F=2`) puskurissa. | ~50 t |
| `REFRESH()` | Rakentaa `MAP`:n ja blittaa koko ruudun z-järjestyksessä: sisus `$0400`:aan, väri `$D800`:aan, reunus + otsikko jos `T`, kursori. Kernel kutsuu itse `WINDOW`/`CLOSE`:ssa; käyttäjä `WINDOWS`-listan käsin muokkauksen tai editorin/grafiikan jälkeen. | ~300 t |
| Puskuriin kirjoittava `put_char`/`newline`/`scroll` + write-through | korvaa nykyisen ruutukoodin (~150 t) | ~280 t |
| TST-entryt, kentänluku, validointi (`LEN(BUF) == W*H`) | | ~60 t |

**Netto ~700 t** (brutto ~850, josta ~150 korvaa nykyistä). Heap: `W*H`
per ikkuna + `MAP` 1000 t; koko ruudun ikkuna 1000 t.

## 2a. Laiska käynnistys — WM on ominaisuus, ei aina päällä

`put_char` käyttää aina ZP-cachea (puskuriosoitin, W, H, R, C; `USE(P)`
kirjoittaa vanhan ikkunan kursorin dictiin ja lataa uuden — ei `dict_get`iä
per merkki). Bootissa cache alustetaan `$0400/40/25`: kirjoitus
"puskuriin" stride 40:llä on suora ruutukirjoitus, ja write-through-
vertailu ohitetaan liputestillä (`MAP == 0`). Yksi koodipolku; nykyinen
suora ruutukoodi korvautuu silti.

Ensimmäinen `WINDOW`-kutsu käynnistää WM:n: varaa `MAP`in ja ROOTin
(dict + 1000 t puskuri), **kopioi nykyisen ruudun ROOTin puskuriin**
(siihenastinen tuloste säilyy saumattomasti), asettaa lipun ja rakentaa
kartan. REPL ilman ikkunoita käyttäytyy täsmälleen kuten nyt, eikä heapia
kulu.

Hinta: +70–100 t verrattuna aina-päällä-versioon. Säästö: 2 KB heapia,
kun ikkunoita ei käytetä. Valinnainen sammutus (~40 t): `CLOSE(ROOT)` kun
muita ikkunoita ei ole → ROOT-puskuri ruutuun, `MAP` vapaaksi, lippu pois;
muuten WM jää päälle resetiin asti.

## 2a2. GC ja ikkunan ZP-cache (katselmuslöydös 2026-09-01)

`put_char`in ZP-cache sisältää raa'an `BUF`-osoittimen; lauseen keskellä
tapahtuva allokaatio → kompaktointi voi siirtää puskurin ja cache roikkuu.
Korjaus: `gc_compact`in häntä re-derefaa nykyisen ikkunan puskurin
cacheen (~20 t; kernel pitää nykyisen ikkunan handlea globaalissa).
Ikkunapuskureita EI pinnata — re-deref on halvempi eikä fragmentoi.

## 2a3. Screen lock (EDIT ym. koko ruudun modaalit)

Globaali lukkolippu: lukon aikana write-through ja `REFRESH` ohitetaan
(tuloste kertyy puskureihin), ja lukon vapautus ajaa `REFRESH()`in.
~15 t. EDIT käyttää tätä WM-vaiheessa; ikkunanatiivi EDIT tulee vasta
multitasking-vaiheessa (ks. PLANS/edit-plugin.md luku 9 ja
PLANS/multitasking.md).

## 2b. Milloin `REFRESH` tarvitaan

Write-throughin ansiosta tavallinen tuloste ei tarvitse refreshiä.
`REFRESH` tarvitaan vain, kun `MAP` vanhenee: ikkunan luonti/sulku (kernel
kutsuu itse), `WINDOWS`-listan käsin muokkaus (siirto `P.X = ...`,
z-järjestys — kirjaston `TOP` kutsuu itse), ja ruudun ulkopuolinen
piirto (editori, grafiikkalaajennukset) → `REFRESH()` paluussa.

Sääntö dokumentoitavaksi: `MAP` sisältää listaindeksin, joten `WINDOWS`-
listan muokkauksen jälkeen tuloste on väärässä paikassa kunnes `REFRESH()`
on ajettu.

## 3. Kirjasto `UI` (Admiral, `examples/ui.admiral`, levyllä)

Ladataan `F = LOAD("UI")`, `UI = F()`. `UI.OPEN` asettaa ikkunan
prototyypiksi `UI`:n (`P._ = ME`), jolloin `UI`:n string-lambdat ovat
ikkunan metodeja. Käyttäjä voi lisätä omia: `UI.FORM = "..."`.

```
# UI.ADMIRAL - IKKUNAT JA VALIKOT
RETURN <
  "OPEN": "P = WINDOW(X, Y, W, H, T)\nP._ = ME\nRETURN P",
  "CLOSE": "CLOSE(ME)",
  "USE": "USE(ME)",

  # TULOSTA TAHAN IKKUNAAN MUUTTAMATTA NYKYISTA KOHDETTA
  "PRINT": "Q = USE(ME)\nPRINT S\nUSE(Q)",
  "STATUS": "Q = USE(ME)\nAT(ME, 0, 0)\nPRINT S\nUSE(Q)",

  # TUO PAALLIMMAISEKSI
  "TOP": "WINDOWS.REMOVE(ME)\nWINDOWS.APPEND(ME)\nREFRESH()",

  # VALIKKO: CRSR-NAPIT, RETURN VALITSEE, F3 PERUU. PALAUTTAA INDEKSIN TAI -1
  "MENU": "K = 0\nWHILE K < LEN(I):\n  AT(ME, 0, K)\n  PRINT I[K]\n  K = K + 1\nS = 0\nW = ME.W\nATTR(ME, 0, 0, W, 1)\nWHILE 1:\n  C = GETC()\n  ATTR(ME, 0, S, W, 2)\n  IF C == 17:\n    S = (S + 1) % LEN(I)\n  ELIF C == 145:\n    S = (S + LEN(I) - 1) % LEN(I)\n  ELIF C == 13:\n    RETURN S\n  ELIF C == 134:\n    RETURN -1\n  ATTR(ME, 0, S, W, 1)",

  "POPUP": "P = ME.OPEN(T=T, X=X, Y=Y, W=W, H=LEN(I))\nR = P.MENU(I=I)\nP.CLOSE()\nRETURN R",
  "ALERT": "P = ME.OPEN(T=T, X=5, Y=10, W=28, H=2)\nPRINT M\nGETC()\nP.CLOSE()",
  "ASK": "P = ME.OPEN(T=T, X=5, Y=10, W=28, H=1)\nS = INPUT(\"\")\nP.CLOSE()\nRETURN S"
>
```

PETSCII: CRSR DOWN 17, CRSR UP 145, RETURN 13, F3 134. (`LIST.REMOVE`
puuttuu vielä — `TOP` vaatii sen tai indeksihaun.)

## 4. Käyttö ohjelmasta

```
F = LOAD("UI")
UI = F()

C = UI.POPUP(T="FILE", I=["LOAD", "SAVE", "RUN", "QUIT"], X=2, Y=2, W=10)
IF C == 0:
  N = UI.ASK(T="LOAD", M="NAME?")
  PROG = LOAD(N)

# JAETTU RUUTU: OHJELMA YLHAALLA, TULKKI ALHAALLA
ROOT = WINDOW(0, 18, 40, 7, "REPL")
APP = WINDOW(0, 0, 40, 17, "APP")
USE(APP)
F = LOAD("GUESS")
F()                                   # TULOSTAA APP-IKKUNAAN
                                      # PALUUN JALKEEN REPL OTTAA ROOTIN
```

Ikkunat saa sulkea missä järjestyksessä vain; päällekkäisyys ratkeaa
z-järjestyksellä refreshissä.

## 4b. ROOT — komentotulkki on ikkuna

*(Multitasking-huomio: N taskin maailmassa globaali ROOT korvautuu
per-task-oletusikkunalla — kunkin taskin ROOT on sen oman prosessi-scopen
muuttuja. Alla oleva kuvaa yksitaskivaiheen.)*

WM:n käynnistyessä (2a) kernel luo `ROOT`in koko ruudun ikkunana ja vie
sen globaaliksi nimeksi. REPL tekee
`USE(ROOT)` ennen jokaista kehotetta, auto-printiä ja virheilmoitusta;
panic-palautus samoin (`ROOT` puuttuu tai on rikki → luodaan uusi koko
ruudun ROOT; WM pois päältä → ei mitään). Käyttäjä säätää sen kuten minkä tahansa ikkunan (esim.
`ROOT = WINDOW(0, 18, 40, 7, "REPL")`). Kun ohjelma palaa tai kaatuu,
REPL ottaa oman ikkunansa takaisin: ohjelman tuloste jää näkyviin.

Toteutushuomiot: REPL:n rivieditointi (`repl.asm:438`) ja editori
(`edit.asm:729`) kirjoittavat nyt suoraan ruuturiveihin; ne siirretään
kirjoittamaan ikkunapuskuriin. Ensivaiheessa `EDIT()` voi käyttää koko
ruutua suoraan ja kutsua `REFRESH()` poistuessaan.

## 4c. Miksi `PRINT` pysyy globaalina lauseena

`PRINT` on parserin lause (`PRINT A, B`), ei funktio; `WINDOW.PRINT`
vaatisi toisen toteutuksen tai rikkoisi kaikki ohjelmat. Malli on sama
kuin Pythonin `print()` → `sys.stdout`: implisiittinen nykyinen kohde,
eksplisiittinen vain tarvittaessa (`P.PRINT(S=...)` kirjastossa).

## 4d. Mitä tämä ei tee

- Ei tapahtumasilmukkaa: `MENU` blokkaa `GETC`:ssä kuten REPL ja editori.
- Ei per-merkki värejä: yksi väri per ikkuna + reverse. Valinnainen
  väripuskuri (`W*H` lisää) voidaan lisätä myöhemmin ilman API-muutosta.
- Ei leikkausta: ikkunan on mahduttava ruudulle.
- Ei suojausta: `P.W = 99` rikkoo ikkunan; kernel tarkistaa vain, ettei
  rikottu dict kaada tulkkia.
- Ei tekstin rivitystä.

## 5. Avoimet päätökset

1. `MAP`:n sijainti: heap-string (GC-juuri, 1000 t heapista) vs. kiinteä alue — kernel-koodin alla ei ole tilaa.
2. Tilan hankinta: ~800 t netto (sis. laiska init + ROOT-sääntö) vaatii joko koodin kutistusta tai FS/RS:n siirron
   ja katon noston (ks. `c64os-feasibility.md` 9.2 ja edellinen keskustelu).
3. Hyppytaulu natiiveille tehdään joka tapauksessa, omana committina ennen
   UI:ta (~50-80 t): lukitsee CODE-laajennusten ABI:n, mahdollistaa
   builtinien siirron levykirjastoiksi, ja UI-primitiivit menevät samaan
   tauluun.
4. Levykirjasto-builtinit ladataan **heapiin TYPE_CODE-arvoina** —
   mekanismi on jo olemassa (`LOAD` + `_llp_code_call`, joka lukee
   osoitteen kahvasta joka kutsulla → GC saa siirtää koodia kutsujen
   välissä, ja GC vapauttaa viittaamattomat). Ehdot: koodi
   paikkariippumatonta (sisäiset hypyt brancheina tai `W0`-itseosoitteen
   kautta), kernel-kutsut vain hyppytaulun kautta, ja **eksplisiittinen `LOAD`**
   (päätetty 2026-08-31: builtin lakkaa olemasta builtin, ei stubeja).
   Kandidaatit: EDIT (-2,5 KB, ks. `PLANS/edit-plugin.md`), SORT, HEX,
   trig-wrapperit (-0,5-1 KB). Ei kiinteää overlay-aluetta.
