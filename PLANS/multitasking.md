# Kaksi taskia: statement-tason preemptio + Admiral-shell

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

## 1. Pinot — vastaus kysymykseen "paljonko kaksisuuntaiset maksaisivat"

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

Suositus: **(b) ensin**; jos 512 t osoittautuu ahtaaksi, (c) on
kymmenen tavun muutos (B:n FS `$8800-$8C00`, RS `$8C00-$9000`,
`HEAP_DATA_START` → `$9000`) — muisti on tässä halvempaa kuin koodi.
(a) hylätään: hinta-hyötysuhde on huonoin ja riski suurin.

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

- **(i) puolitus**: ketju jää paikoilleen (A `S=$FF`, B `S=$7F`).
  Nollakustannus vaihdossa; syvyys 128 t/task ≈ 10–12 sisäkkäistasoa
  (sama luokka kuin FS-puolikkaan 23 kehystä).
- **(ii) kopiointivaihto**: yksi jaettu pino; vaihdossa käytetty osa
  kopioidaan taskin puskuriin ja toisen ketju takaisin. Mitatuilla
  syvyyksillä 30–80 t → ~1–2 ms/vaihto; ei syvyysrajaa; +2×~128 t
  puskureita + ~40 t koodia.

Valinta jätetään auki kunnes oikeiden ohjelmien (mcdemo, neuron) syvyys
on mitattu; datan valossa (ii) voi olla parempi, koska kopioitavaa on
vähän eikä syvyysraja puolitu. Kummassakin tapauksessa `preamble`en
SP-alarajavahti (~10 t): ylivuoto panikoi siististi eikä korruptoi.

## 3. Task-tila ja vaihto

Per-task (vaihdetaan ~60–70 t save-alueeseen): `FSP RSP FP W0-W3 B0-B7 RV
RV2 LEX_* CURRENT_SCOPE METHOD_RECEIVER SCREEN_ROW/COL` + HW-`SP` + oma
ikkuna (WM-dict).

Jaettua (ei vaihdeta): allokaattori + GC (`NEXT_HANDLE NEXT_DATA FREE_HEAD
RESERVED_HEAD GC_COUNTER ALLOC_*`), `ROOT_SCOPE`? — **avoin kysymys**:
jaettu globaali scope (taskit näkevät toistensa muuttujat; helppo, vaarallinen)
vs. oma ROOT_SCOPE per task (eristys; IPC:ksi tarvitaan jokin kanava).

GC-muutos: mark kävelee molempien taskien aktiiviset RS-alueet
(`RSP_A..$8800` ja `RSP_B..$8400`), ~30 t. FS ei ole GC:n skannaama ✓.

Kustannusarvio kernelissä: vaihto ~150 t, ajastinlippu ~30 t, GC ~30 t,
vahdit ~30 t, fokusreititys ~40 t ≈ **~300 t**. (WM:n päälle; osa voi
elää WM-pluginissa, mutta `task_switch`in on oltava kernelissä — sitä
kutsutaan `parser_stmt`istä.)

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
statement-rajojen läpi → kaikki on vaihdettavissa, ja "kaksi taskia" =
kaksi shell-instanssia omissa ikkunoissaan.

## 7. Toteutusjärjestys

1. WM (ui-primitives v4) — taskit ilman ikkunoita sotkisivat ruudun.
2. `EXEC` + SHELL + error_handler-ohjaus — hyödyllinen yksinkin
   (muokattava shell), ja tekee vaihtopisteistä kattavia.
3. HW-pinon syvyysvahti + mittaus oikeilla ohjelmilla.
4. Task-tila, `task_switch`, ajastinlippu, GC:n kaksialuemark.
5. kbd-yield + fokus + C=+TAB.

## 8. Avoimet kysymykset

1. Jaettu vai eriytetty `ROOT_SCOPE` (luku 3)?
2. `parser_exec`in tarkka sopimus — riittääkö `EXEC`ille sellaisenaan?
3. HW-pino: puolitus vs. kopiointivaihto (luku 2) — mitattava
   mcdemo/neuron-tason ohjelmilla ennen valintaa.
4. Ajastimen lähde: IRQ on nyt käytössä ($0314-polku) — riittääkö nykyinen
   jiffy-IRQ lipun asettajaksi vai tuleeko WM:n myötä jotain muuta?
5. Paniikki keskellä pluginia toisen taskin ollessa pinnattuna samassa
   payloadissa: pin-lippujen siivous error_handlerissa (kirjattu jo
   edit-plugin-työssä, toteuttamatta).
