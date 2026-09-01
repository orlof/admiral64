# N taskia: statement-tason preemptio + Admiral-shell

Tila: luonnos (2026-09-01), muokataan. Edeltäjät: `PLANS/ui-primitives.md`
(WM), `PLANS/edit-plugin.md` (plugin-ABI). Riippuvuusjärjestys:
WM → `EXEC` + SHELL → taskit.

## 0. Perusrajaus: statement-tason preemptio, ei käskytason

Tulkin ZP-tila sisältää raakoja osoittimia heap-payloadeihin (`W2`-derefit,
`LEX_PTR/LEX_END`). Mielivaltaisessa kohdassa keskeytetyn taskin osoittimet
roikkuvat heti, kun toinen task allokoi ja GC kompaktoi. Statement-rajalla
elävä tila on FS/RS-pinoissa (GC-juurrettuja handleja) ja lexer-tila
palautettavissa `LEX_SRC_HANDLE`n kautta. Siksi:

- **Ajastin-IRQ asettaa vain lipun** (`SWITCH_PENDING`).
- **`parser_stmt`-raja tarkistaa lipun** ja kutsuu `task_switch`in (~15 t
  tarkistus statementtia kohti).
- Käyttäjäsilmukat ovat statementtejä → pitkät ohjelmat vaihtuvat
  sulavasti. Yksittäinen pitkä builtin (esim. ison listan SORT) ei
  keskeydy — hyväksytään.

## 1. Pinot

**Päähavainto:** kahden taskin raja oli staattisen puolituksen artefakti.
`FSP`/`RSP` ovat ZP-osoittimia — pinot voivat asua missä tahansa, kunhan
kiinteät `FS_*`/`RS_*`-vakiot (init, GC-kävely, ylivuotovahdit) muutetaan
per-task-muuttujiksi. Valittu malli:

- **Taskin pinot allokoidaan heapista luonnissa ja pinnataan**
  (`FLAG_PINNED` + `gc_compact`-ohitus ovat jo olemassa). Task ≈ FS-lohko
  (oletus 512 t, `SPAWN`-parametri) + RS-lohko (512 t) + HW-puskuri
  (128 t) + ZP-save (~70 t) + ikkunaviite ≈ **~1,3 KB heapia / task**.
- Pysyvän pinnauksen fragmentointihaitta on pieni: pinot asettuvat
  matalalle luontihetkellä ja vapautuvat kokonaan taskin päättyessä.
- 30 KB:n heapilla realistinen katto 3–5 taskia; raja on muisti, ei
  osoitekartta.
- GC:n mark: silmukka task-taulun yli, kunkin `RSP_i..RS_END_i`.
- **Myös task 0:n pinot ovat osa heapia:** `HEAP_DATA_START` muuttuu
  vakiosta muuttujaksi (luetaan 3 paikassa: `alloc_init`, `gc_compact`,
  `MEM()`; ennakkotapaus `HEAP_TOP` on jo muuttuja). Boot carvaa task 0:n
  FS+RS:n heapin pohjalta ennen allokaattorin käynnistystä (allokaattori
  tarvitsee pinoja → task 0:n lohkot ovat handlettomia raakalohkoja
  task-taulussa; GC ei koske niihin, koska kompaktointi alkaa
  `HEAP_DATA_START`ista niiden yläpuolelta). Oletuscarve tuottaa
  nykyisen layoutin tavutarkasti ($8000/$8400/$8800 → nolla testi-
  muutosta), mutta task 0:n pinokoko on jatkossa boot-päätös: 512+512
  riittäessä heap kasvaa 30 → 31 KB myös yksitaskikäytössä. Erillistä
  pinovarausta ei ole enää käsitteenä — on vain heap.

Alla alkuperäinen kahden taskin vertailu taustaksi — puolitus (b) jää
degeneroituneeksi erikoistapaukseksi eikä ole enää suositus.

### Tausta: "paljonko kaksisuuntaiset stackit maksaisivat"

Kasvusuunta on leivottu koodiin kolmessa kerroksessa:

1. `stacks.asm` (368 t): kaikki `fs_push/pop/peek`- ja `rs_push/pop/peek`-
   primitiivit dekrementoivat/inkrementoivat kiinteään suuntaan
   (~15 aliohjelmaa + makrolaajennokset).
2. `preamble.asm` (334 t): V4'-kehyksen layout (22 t kehys `FP`+offset
   -osoituksella) olettaa alaspäin kasvun; peilattu kehys kääntäisi
   kaikki offsetit, myös `arg_get`-polut.
3. `gc.asm`: markkaus kävelee RS:n lineaarisesti `RSP → RS_END` ylöspäin.

Ylöspäin kasvava variantti = peilikopiot kerroksista 1–2 (~450–550 t) TAI
suuntavektorit ZP:ssä (~15 vektoria, +3 sykliä *jokaiseen* pino-operaatioon
— kuumin polku koko tulkissa) + kerroksen 3 varianti. Lisäksi jokainen
tuleva pinokoodin muutos pitäisi tehdä kahdesti.

**Vertailu:**

| Vaihtoehto | Koodi | Muisti | Pino/task |
|---|---|---|---|
| (a) Kaksisuuntaiset pinot | +450–550 t (tai +3 syk/op) | 0 | dynaaminen, yht. 1 KB |
| (b) Puolitus: eri init-arvot | **~0 t** | 0 | 512 t FS, 512 t RS |
| (c) Task B:n pinot heapin alusta | ~10 t (init) | −2 KB heap | täydet 1 KB + 1 KB |

(a) hylätään: hinta-hyötysuhde on huonoin ja riski suurin. (b) ja (c)
korvautuvat yllä olevalla heap-allokoidulla mallilla, joka on (c):n
N-yleistys.

## 2. Laitteistopino — miksi suspendoitu task tarvitsee oman tilan

**Ei blokkaavien kutsujen takia**, vaan koska tulkin jatkokohta elää
natiivina rekursiona `$0100`-sivulla: rekursiivisesti laskeutuvan tulkin
JSR-ketju (`parser_stmt → expression → led → eval → parser_stmt → ...`)
peilaa Admiral-tason kutsusyvyyttä. Statement-raja on GC-turvallinen
vaihtokohta, mutta ei natiivipinon pohja — sisäkkäisen funktion tai
WHILE-rungon lauseiden välissä pinossa ovat kaikkien ulompien tasojen
kehykset, ja ne on säilytettävä kunnes task jatkaa. Blokkaava `INPUT()`
lausekkeen sisällä on vain tämän syvin erikoistapaus.

Tarve katoaisi vain, jos (a) vaihdettaisiin vain ylimmän tason
lauserajalla — jolloin pitkä ohjelma ei koskaan luovuta, preemptio katoaa
— tai (b) tulkki kirjoitettaisiin ei-rekursiiviseksi (jatkokohta
eksplisiittisesti FS:ssä; natiivipino tyhjä lauserajoilla). (b) olisi
"oikea" ratkaisu ja tekisi vaihdosta pelkän ZP+FSP/RSP-swapin, mutta se
on parserin/evalin uudelleenkirjoitus — rajattu pois.

Mitattu syvyysdata (py65, min-SP suorituksen aikana):

| Ohjelma | HW-pinoa käytössä |
|---|---|
| suora lauseke | 29 t |
| syvä lauseke `((((((1+2)*3+4)...` | 53 t |
| 5 sisäkkäistä funktiokutsua | 49 t |
| 8-tasoinen Admiral-rekursio | 81 t |

≈ 29 t pohja + 6–10 t per Admiral-sisäkkäistaso.

Kaksi toteutusta ketjun säilyttämiselle:

- **(i) puolitus**: vain 2 taskia, syvyys 128 t/task. Hylätty — lukitsee
  taskimäärän.
- **(ii) kopiointivaihto** (valittu): yksi jaettu pino; vaihdossa käytetty
  osa kopioidaan taskin puskuriin (task-oliossa heapissa) ja tulevan
  taskin ketju takaisin. Mitatuilla syvyyksillä 30–80 t → ~1–2 ms/vaihto,
  N:stä riippumaton; ei syvyysrajaa; ~128 t puskuri/task + ~40 t koodia.

`preamble`en SP-alarajavahti (~10 t): ylivuoto panikoi siististi eikä
korruptoi.

## 3. Task-tila ja vaihto

Per-task (vaihdetaan ~60–70 t save-alueeseen): `FSP RSP FP W0-W3 B0-B7 RV
RV2 LEX_* CURRENT_SCOPE METHOD_RECEIVER SCREEN_ROW/COL` + HW-`SP` + oma
ikkuna (WM-dict).

Jaettua (ei vaihdeta): allokaattori + GC (`NEXT_HANDLE NEXT_DATA FREE_HEAD
RESERVED_HEAD GC_COUNTER ALLOC_*`).

### Scope-analyysi (2026-09-01)

Faktapohja: scope-ketju kulkee `_`-parent-linkillä (`scope_get` kävelee),
funktioscopet saavat ROOT_SCOPEn vanhemmakseen, kirjoitus varjostaa
sisimpään, `error_handler` palauttaa CURRENT_SCOPEn ROOT_SCOPEsta.

| | 2: vain globaali | 3: vain prosessi | 1: globaali + prosessi |
|---|---|---|---|
| Toteutus | 0 t | **0 t** (ROOT/CURRENT_SCOPE jo vaihtolistalla) | +1 rivi (task-rootin `_` → jaettu dict; scope_get kävelee itsestään) |
| Top-level-muuttujat | törmäävät (kahden shellin `I`, `TMP`...) — killeri | eristetty | eristetty (varjostus) |
| Paniikki | resetoi jaettua | eristyy taskiin | eristyy taskiin |
| Moduulikirjastot | 1 LOAD, mutta tilalliset moduulit (esim. `A.GO()` mutatoi `ME.LBL`) ja jaettu EDIT-payload kilpailevat | **ei muutoksia**: LOAD per task, yhdenmukainen plugin-instanssisäännön kanssa | luettavissa jaetusti, mutta mutaatio viittauksen läpi (`UI.X = 5`) osuu jaettuun → vaatii konvention "vain tilattomat jaetaan" |
| Muisti | halvin | duplikaatio (UI ~100 t/task; EDIT 3,5 KB/käyttävä task — sääntö oli jo) | välissä |
| NONE-rajoite | — | — | jaetun nimen varjostus NONElla puhkaisee ketjun |

**Päätösesitys: 3 nyt.** 1 on 3:n yhteensopiva myöhempi laajennus
(`_`-linkin lisäys ei muuta olemassa olevaa koodia); jakaminen tuodaan
tarvittaessa eksplisiittisenä builtin-välitteisenä kanavana (`SYS`-dict
tai SEND/RECV), jolloin se on opt-in eikä nimihaun sivuvaikutus.
2 hylätään.

GC-muutos: mark kävelee task-taulun kaikkien taskien aktiiviset RS-alueet
(`RSP_i..RS_END_i`), ~50 t. FS ei ole GC:n skannaama ✓.

Kustannusarvio kernelissä: vaihto ~150 t, ajastinlippu ~30 t, GC ~50 t,
vahdit ~30 t, fokusreititys ~40 t, task-taulu + round-robin ~60 t,
elinkaari (`SPAWN(F [, STACK])`, `EXIT`, siivous) ~150-200 t ≈
**~550-600 t**. (WM:n päälle; osa voi
elää WM-pluginissa, mutta `task_switch`in on oltava kernelissä — sitä
kutsutaan `parser_stmt`istä.)

## 3b. WM-yhteentoimivuus (katselmus 2026-09-01)

- Taskin ZP-vaihtolistaan kuuluu myös WM:n kohdecache (BUF-osoitin, W, H,
  R, C, ikkunaindeksi). `task_switch` **re-resolvaa tulevan taskin
  kentät sen ikkunadictistä** (~30 t) — kattaa sekä toisen taskin
  aiheuttamat GC-siirrot että WINDOWS-listan muutokset suspendin aikana.
  Statement-atomisuus takaa, ettei lista/MAP muutu kesken timeslicen.
- Sääntö: vain omistajataski sulkee ikkunansa.
- Per-task-oletusikkuna: `SPAWN` luo taskille ikkunan ja sen ROOT on
  taskin oman scopen muuttuja (prosessi-scope tekee tästä luontevan).
- Fokusvaihto (C=+TAB) nostaa taskin ikkunan päällimmäiseksi
  (WINDOWS-järjestys + REFRESH).
- **EDIT ikkunanatiiviksi tässä vaiheessa** (WM-vaiheessa se on koko
  ruudun modaali screen lockilla): (1) `SYS_SCR_ROW_W2_A` → rivin kanta
  nykyisen ikkunan puskuriin (stride W), plugin ei muutu; (2) uusi
  SYS-kysely: nykyisen kohteen W/H → EDITin ~10 geometria-immediatea
  latauksiksi (~30 t pluginissa); (3) inline-GETIN → uusi
  `SYS_KBD_GETCHAR`-slotti → kbd-yield + fokus ilmaiseksi;
  (4) **edit_grow-korjaus**: paikallaan-bump nojaa invariantteihin
  "puskuri ylin allokaatio" ja "sessiossa ei allokoida", jotka toinen
  task rikkoo → grow palaa alloc+kopioi-malliin JA EDIT pinnaa
  puskurinsa session ajaksi (uudet `SYS_PIN`/`SYS_UNPIN`-slotit, ~20 t —
  ilman pinnausta B:n GC siirtää A:n puskuria ja A:n editoritila
  roikkuu resumessa).

## 4. Blokkaavat kutsut

Kaikki syöte kulkee `kbd_getchar`-spinin kautta → siitä yield-piste:
"jos en ole fokusoitu task TAI näppäintä ei ole → `task_switch`".
Seuraukset:

- `GETC`/`INPUT`/EDIT-sessio luovuttavat automaattisesti odottaessaan
  (EDIT pollaa näppäimiä pluginin sisällä → vaihto tapahtuu sielläkin).
- Fokusvaihto hotkeyllä (esim. C=+TAB) `kbd`-polussa: vaihda fokus-task +
  `REFRESH`.
- Levy-I/O ei keskeydy (sarjaväylän ajoitus, IRQ:t maskattuna) —
  hyväksytään; vaihto odottaa.

## 5. Pluginien uudelleentulo

Task A voi olla suspendoituna *pluginin sisällä* (EDIT odottaa näppäintä).
Jos B kutsuu samaa payloadia, pluginin staattinen tila (payloadin sisällä)
menee sekaisin. Ratkaisu on ilmainen: **kukin task tekee oman
`LOAD("EDIT")`-kutsunsa** → kaksi payload-kopiota → kaksi instanssia.
Dokumentoidaan sääntönä. (Pin-lippu toimii oikein: A:n pinnattu payload ei
liiku B:n GC:ssä.)

## 6. Shell Admiral-koodiksi

Palaset: stringit ovat kutsuttavia; `parser_exec` on olemassa
("REPL-flavored variant that reuses caller's scope" — tarkka sopimus
varmistettava). Tarvitaan:

1. `EXEC(S)`-builtin → `parser_exec` (~30 t): suorittaa S:n kutsujan
   scopessa, auto-print-semantiikalla.
2. `error_handler`-uudelleenohjaus: paniikki → resetoi *nykyisen taskin*
   pinot → tulosta virhe → käynnistä `SHELL`-globaali uudelleen (~40 t).
   Kernelin minimi-REPL jää fallbackiksi (SHELL puuttuu/rikki → nykyinen
   käytös).
3. `examples/shell.admiral`: `WHILE 1: EXEC(INPUT("] "))` + prompt +
   mahdolliset aliakset — käyttäjän muokattavissa.

Hyöty taskeille: kun shell on Admiral-koodia, kaikki suoritus kulkee
statement-rajojen läpi → kaikki on vaihdettavissa, ja taskit ovat
shell-/ohjelmainstansseja omissa ikkunoissaan (`SPAWN` shellistä).

## 7. Toteutusjärjestys

1. WM (ui-primitives v4) — taskit ilman ikkunoita sotkisivat ruudun.
2. `EXEC` + SHELL + error_handler-ohjaus — hyödyllinen yksinkin
   (muokattava shell), ja tekee vaihtopisteistä kattavia.
3. HW-pinon syvyysvahti + mittaus oikeilla ohjelmilla.
4. Task-tila, `task_switch`, ajastinlippu, GC:n kaksialuemark.
5. kbd-yield + fokus + C=+TAB.

## 8. Avoimet kysymykset

1. Scope: PÄÄTETTY 2026-09-02 — vain prosessi-scope (luvun 3 analyysi);
   jaettu read-through (`_`-linkki) mahdollinen yhteensopiva laajennus
   myöhemmin.
2. `parser_exec`in tarkka sopimus — riittääkö `EXEC`ille sellaisenaan?
3. HW-pino: puolitus vs. kopiointivaihto (luku 2) — mitattava
   mcdemo/neuron-tason ohjelmilla ennen valintaa.
4. Ajastimen lähde: IRQ on nyt käytössä ($0314-polku) — riittääkö nykyinen
   jiffy-IRQ lipun asettajaksi vai tuleeko WM:n myötä jotain muuta?
6. Task 0:n oletuspinokoko (1024+1024 kuten nyt vs. 512+512 + 1 KB lisää
   heapia) — päätettävä FS/RS-käyttömittauksella oikeista ohjelmista.
5. Paniikki keskellä pluginia toisen taskin ollessa pinnattuna samassa
   payloadissa: pin-lippujen siivous error_handlerissa (kirjattu jo
   edit-plugin-työssä, toteuttamatta).
