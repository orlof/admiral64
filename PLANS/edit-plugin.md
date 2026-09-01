# EDIT levyladattavaksi TYPE_CODE-pluginiksi — tutkimus

Tila: tutkittu, toteutuskelpoinen (2026-08-31). Tausta:
`PLANS/ui-primitives.md` luku 5 kohta 4. Päätetty politiikka:
**eksplisiittinen lataus** — `E = LOAD("EDIT")`, `S = E(S)`; EDIT lakkaa
olemasta builtin (TST-entry poistuu).

## 1. Mitä siirretään

- `edit.asm` (2051 t): gap-bufferieditorin ydin.
- `builtin_edit`-lohko `builtins.asm`:ssä (~365 riviä ≈ 500–700 t):
  argumentin käsittely, puskurin alustus, pääsilmukka (`_bedit_loop`),
  F-näppäimet, tuloksen rakentaminen.

Yhteensä **~2,5–2,7 KB pois PRG:stä**.

## 2. Riippuvuusanalyysi (mitattu)

Ulkoiset `jsr/jmp`-kohteet ovat harvassa:

- `edit.asm`: vain `scr_row_offset_to_w2_a`, `petscii_to_screen_code`.
- `builtin_edit`-lohko: `str_alloc`, `deref_W0_to_W2`, `arg0_w0_deref`,
  `screen_clear`, `screen_show_cursor`, `screen_hide_cursor`,
  `panic_type`, `postamble`-perhe (+ `preamble_call`-makron sisäiset).
- `rs_push`/`rs_peek`/`fs_*`-makrot laajenevat inlineen ja käyttävät
  ZP-osoittimia → paikkariippumattomia sellaisenaan.
- `KERNAL_GETIN`-pollaus on inline-koodia pankkivaihtoineen → PIC-ok.

→ Hyppytauluun tarvitaan **~12–15 entryä**, jotka kaikki ovat muutenkin
taulun ilmeisiä jäseniä.

## 3. GC-turvallisuus — avainlöydös

Editorin pääsilmukalla on tiukka **"ei allokaatioita"-invariantti**:
`edit_grow` kasvattaa puskuria *paikallaan* bumppaamalla `NEXT_DATA`a
(puskuri on ylin heap-allokaatio), eikä mikään muu silmukassa allokoi.
Siis **GC ei voi käynnistyä kesken edit-session** → siirtyvä koodi ei ole
ongelma session aikana. Invariantti säilyy pluginina: koodiolio ladataan
ennen puskurin allokointia, joten puskuri on yhä ylin.

Ainoat allokaatiot tapahtuvat prologissa (3 × `str_alloc`) ja
epilogissa (tulos-string) — *plugin-koodin suorituksen aikana*, jolloin
GC voisi siirtää suorituksessa olevan koodin. Ratkaisu: **pin-lippu**
`H_FLAGS`iin — `_llp_code_call` asettaa sen kutsun ajaksi ja
`gc_compact` jättää pinnatun lohkon paikalleen (kompaktointi jatkuu sen
yli; reikä siistiytyy seuraavassa ajossa). ~30 t, hyödyttää kaikkia
plugineja.

## 4. PIC-ongelma ja ratkaisu: relokaatiotaulu

Käsin-PIC ei ole realistinen: ~85 sisäistä absoluuttista `jsr/jmp`:tä ja
kymmeniä absoluuttisia viittauksia editorin staattiseen tilaan (25 tavua
`edit_buf_handle`...`edit_clip_cut`, jotka pluginissa elävät koodi-
payloadin sisällä — kirjoitus omaan payloadiin on RAMissa ok).

Sen sijaan **relokaatio latauksessa/kutsussa**:

- `tools/build_plugin.py`: assembloi KickAssemblerilla kahteen baseen
  (esim. $1000 ja $1100), diffaa binäärit → hi-tavu-fixup-lista.
- Payload: `[linked_base:2][nfix:2][fixup-offsetit:2*n][koodi]`.
- Koodin alussa 5 tavun prologi: `jsr SYS_RELOC` (hyppytaulun kiinteä
  osoite). `SYS_RELOC` saa koodin todellisen basen `W0`:sta (ABI:n
  olemassa oleva konventio), vertaa `linked_base`en ja ajaa fixupit jos
  olio on siirtynyt edellisen kutsun jälkeen. ~80 t kernelissä;
  ~200 fixupin ajo < 50k sykliä ≈ 50 ms — merkityksetön kutsun alussa.

Tämä mekanismi on geneerinen: sama työkalu ja `SYS_RELOC` kelpaavat
kaikille isoille plugineille.

## 5. Paluuarvo-ABI:n laajennus

`_llp_code_call` palauttaa nyt vain `W0`:n inline-intinä 0..65535 —
`EDIT` palauttaa TYPE_STR:n. Laajennus: **carry set paluussa → `W0` on
handle**, joka palautetaan sellaisenaan (RV = W0). ~15 t dispatcheriin,
taaksepäin yhteensopiva (nykyiset pluginit palaavat carry clearillä —
varmistettava `asm.admiral`in generoimasta koodista ja esimerkeistä).

## 6. Budjetti

| | t |
|---|---|
| PRG:stä pois (edit.asm + _bedit-lohko + TST-entry) | **−2500…−2700** |
| `SYS_RELOC` | +80 |
| pin-lippu GC:hen | +30 |
| carry-paluu dispatcheriin | +15 |
| hyppytaulu (tehdään joka tapauksessa) | (+50…80) |
| **Netto** | **≈ −2,4 KB** |

Kattaa UI-suunnitelman ~880 t lähes kolminkertaisesti. Heap-kustannus
editoinnin aikana: ~2,7 KB koodia + puskuri; GC vapauttaa kun `E`-viite
poistuu.

## 7. Haitat ja reunaehdot

- `EDIT(...)`-kutsut ohjelmissa ja dokumentaatiossa muuttuvat:
  `E = LOAD("EDIT")` ensin. `examples/help.admiral`, `README.md`,
  `mcdemo` ym. päivitettävä; F1/F3-semantiikka säilyy.
- Ensimmäinen käyttö vaatii levyn asemassa ja kestää ~2 s (1541).
- py65-testit: EDIT-testien on ladattava plugin `KernalDiskMock`in kautta
  (`hd`-fixture) — testijärjestely muuttuu.
- Editorin ruutupiirto (`scr_row_offset_to_w2_a`) kirjoittaa suoraan
  ruuturiveihin; UI/WM-maailmassa (ui-primitives v4) sen on kirjoitettava
  ikkunapuskuriin — hyppytaulun entry vaihdetaan silloin, plugin ei muutu
  jos entry-semantiikka pidetään "rivin base-osoite nykyiseen kohteeseen".
- Järjestys: hyppytaulu → SYS_RELOC + pin + carry-paluu → EDIT-siirto.
  UI voidaan tehdä ennen tai jälkeen; jälkeen on helpompi (tilaa on).

## 8. Seuraava askel

1. Hyppytaulu + `SYS_RELOC` + pin + carry-paluu (kernel, ~200 t).
2. `tools/build_plugin.py` (kaksois-assemblointi + diff + pakkaus
   TYPE_CODE-recordiksi levylle).
3. Siirrä ensin pieni builtin (esim. `SORT`) koko putken savutestinä.
4. Sitten EDIT.

## 9. EDIT ja ikkunointi/multitasking (katselmus 2026-09-01)

Mitatut sidokset: ~10 käännösaikaista geometria-immediatea
(`SCREEN_COLS/ROWS`), rivikanta `SYS_SCR_ROW_W2_A`n takana, kursori
`SCREEN_ROW/COL` + kaksi slottia, näppäimet inline-`KERNAL_GETIN`.

Vaiheistus:
- **WM-vaihe:** EDIT pysyy koko ruudun modaalina; screen lock vaimentaa
  muiden ikkunoiden write-throughin ja poistuminen ajaa `REFRESH()`in.
  Nolla muutosta pluginiin.
- **Multitasking-vaihe:** ikkunanatiivi — ks. PLANS/multitasking.md 3b
  (rivikannan uudelleenkohdistus, W/H-kysely, `SYS_KBD_GETCHAR`,
  edit_grow → alloc+kopioi + puskurin pinnaus `SYS_PIN`illä).
  Palkinto: editori missä tahansa ikkunassa (split-screen editori+REPL).

Kriittinen löydös: `edit_grow`in paikallaan-bump ja "ei allokaatioita
sessiossa" -invariantti eivät kestä toista taskia — sekä bump-törmäys
että GC-siirto suspendin aikana. Korjaus multitasking-vaiheessa
pakollinen ennen kuin EDIT-sessio saa elää taustalla.
