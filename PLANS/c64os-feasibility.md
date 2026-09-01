# Admiral64 C64 OS:n sisällä — alustava feasibility study

Päiväys: 2026-08-30. Tila: **päätetty — ei portata** (ks. luku 10).

## 1. Mitä C64 OS on (oletukset, joihin arvio nojaa)

C64 OS (Greg Naçu, 1.0 julkaistu 2022) on KERNAL-pohjainen, tapahtumavetoinen
työpöytäkäyttöjärjestelmä hiirellä, valikoilla, Utility-ikkunoilla ja omalla
tiedostojärjestelmäabstraktiolla (CMD/SD2IEC-hakemistot, osiot, polut).

Muistikartta (blogin "rethinking the memory map" -versio — **HUOM: vanhentunut,
ks. luku 9.1; v1.0:n todellinen kartta on toinen**):

| Alue            | Sisältö                                                         |
|-----------------|-----------------------------------------------------------------|
| $0000-$04FF     | ZP, HW-pino, järjestelmämuuttujat, sivukartta (page map)         |
| $0500-$AFFF     | **Sovellustila, ~42 KB.** `main` ladataan mieluiten $0800:aan    |
| $B000-$CFFF     | C64 OS KERNAL (4+4 KB; $B000-$BFFF on BASIC ROMin alla)          |
| $D000-$DFFF     | I/O; sen alla VIC bank 3: oma merkistö, tekstiruutu, väripuskuri |
| $E000-$FFFF     | Commodore KERNAL ROM **pysyy sisällä**; sen alla RAMissa Utilityt |

Sovellusmalli: `main` on ei-siirrettävä koodi; OS kutsuu init-rutiinia,
sovellus työntää "screen layerin" (piirtorutiini + tapahtumakäsittelijät) ja
**palaa OS:n event-looppiin**. OS omistaa IRQ:n, hiiren, näppäimistön,
ruudun kompositoinnin ja $01-vaihdot piirron aikana. Muisti jaetaan
sivuittain (`pgalloc`), ja `main`in sivut merkitään varatuiksi latauksessa.

Natiivi PRG voidaan ajaa PRG Runnerilla, mutta se pudottaa koneen ulos
OS:stä; paluu vaatii uudelleenkäynnistyksen (REU:lla nopean).

## 2. Admiral64:n nykyiset oletukset vs. C64 OS

| # | Admiral64 nyt                                                       | C64 OS                                                    | Ristiriita |
|---|---------------------------------------------------------------------|-----------------------------------------------------------|-----------|
| 1 | Koodi $0801-~$7FFC (30,6 KB)                                        | Sovellustila $0500-$AFFF                                  | ei — mahtuu |
| 2 | FS $8000-$83FF, RS $8400-$87FF                                      | sovellustilan sisällä                                     | ei |
| 3 | Heap $8800-$FFF8 (~30 KB) — data ylös, handlet alas $FFF8:sta       | Vapaata vain $8800-$AFFF ≈ **10 KB**                      | **SUURI** |
| 4 | Steady state `$01=$34` (kaikki ROMit ulkona), oma IRQ/NMI $FFFA/$FFFE | KERNAL ROM sisällä, OS omistaa IRQ:n/NMI:n, I/O sisällä  | **SUURI** |
| 5 | BASIC ROM FP-rutiinit `$01=$37`                                     | $37 peittää C64 OS -ytimen $B000-$BFFF                    | keski |
| 6 | ZP $02-$4A (~75 tavua) + $53-$70 FP-scratch                         | OS + KERNAL ROM käyttävät ZP:tä; sovellukselle rajattu osa | keski (tarkistettava) |
| 7 | Ruutu suoraan $0400/$D800, VIC bank 0, oma $D018                    | VIC bank 3, oma merkistö, layer-pohjainen piirto           | keski |
| 8 | Blokkaava `kbd_getchar_spin` (REPL, INPUT, GETC, editori)           | Yhteistoiminnallinen event-loop: sovelluksen on palattava  | **SUURI** (arkkitehtuurinen) |
| 9 | Levy: suorat KERNAL SETLFS/OPEN/CHKIN, 1541-nimet                   | OS:n tiedostoviitteet, polut, osiot                        | keski |
| 10| RUN/STOP-, RESTORE-banneri, ajastin-IRQ                             | OS omistaa NMI:n                                           | pieni (poistetaan) |
| 11| Build: yksi `admiral.prg` + d64                                     | App-bundle-hakemisto (`main`, `menu.m`, …)                | pieni |

## 3. Analyysi kohdittain

### 3.1 Muisti — dominoiva riski
Koodi 30,6 KB + pinot 2 KB syövät 42 KB:n sovellustilasta 32,6 KB → heapille
jää n. **9–10 KB**, kolmasosa nykyisestä. Tulkki toimii, mutta esim.
`examples/`-ohjelmat ja editorin puskuri kilpailevat samasta tilasta.

Lievennykset:
- Heapin rajat parametrisoidaan init-aikaisiksi muuttujiksi (`HEAP_DATA_START`,
  `HEAP_HANDLE_START` ovat nyt vakioita; `HEAP_HANDLE_START_GFX` osoittaa että
  ylärajan vaihtaminen on jo osittain tuettu). Rajat haetaan `pgalloc`ilta
  yhtenä yhtenäisenä sivulohkona.
- Koodin kutistaminen: `fs_push_byte`-makrojen korvaus `_call`-muodoilla,
  harvinaiset builtinit ehdolliseen käännökseen (`#if C64OS`).
- Ei REU-riippuvuutta: Admiralin handle-epäsuoruus mahdollistaisi periaatteessa
  datalohkojen sivutuksen REU:hun, mutta se on oma projektinsa.

### 3.2 $01-pankitus ja keskeytykset
Steady state on vaihdettava `$34` → `$36`/`$37`:ään (KERNAL + I/O sisällä),
koska C64 OS:n IRQ-käsittelijä olettaa I/O:n ja KERNALin näkyviksi. Tämä on
yhdenmukainen kohdan 3.1 kanssa: heap ei enää asu $D000+/$E000+ alla, joten
`$34`:ää ei tarvita mihinkään. `MEM_NORMAL`-vakio + `keyboard.asm`:n omat
vektorit ovat ainoat kovat riippuvuudet — helppo eristää `#if`-lipulla.

FP-kutsut (`basic_op`-envelope) vaativat `$37`, joka piilottaa OS-ytimen
$B000-$BFFF. Jos IRQ osuu tähän ikkunaan ja OS:n IRQ hyppää $B000-koodiin,
kone kaatuu. Korjaus: `sei`/`cli` envelopessa (FP-kutsut ovat millisekunteja;
hiiri/ajastin jitteröi hieman). Vaihtoehtoisesti kopioidaan tarvittavat
FP-rutiinit RAMiin — ei mahdu.

### 3.3 Nollasivu
Admiral omistaa $02-$4A yhtenäisenä lohkona plus FP-scratchin $53-$70.
KERNAL ROM (elossa!) käyttää $90-$FF:ää levy-I/O:ssa — ei päällekkäisyyttä.
C64 OS:n oma ZP-käyttö on tarkistettava Programmer's Guiden liitteestä.
Jos päällekkäisyyttä on, ratkaisu on sama kuin nykyinen
`_basic_zp_save/_restore`: swapataan Admiralin ZP-lohko puskuriin aina kun
kontrolli siirtyy OS:lle (~75 tavua, halpaa).

### 3.4 Ruutu
`screen.asm` on ohut kerros (`SCREEN_BASE`/`COLOR_BASE` + kursori).
Suositus: Admiral piirtää omaan 1000-tavun screen-code-puskuriin, ja C64 OS
-layerin draw-rutiini kopioi sen OS:n tekstiruutuun. Riski: C64 OS:n oma
merkistö ei välttämättä vastaa PETSCII-screen-code-taulukkoa 1:1 (UI-glyfit),
jolloin tarvitaan muunnostaulukko. Vaihtoehto "takeover" (sovellus omii VIC:n)
— katso 4.

### 3.5 Kontrollin kääntö — arkkitehtuurinen ydinongelma
Admiral on push-tyyppinen: `kbd_getchar_spin` blokkaa syvällä kutsupinossa
(REPL → tulkki → `INPUT()` → …). C64 OS on pull-tyyppinen: tapahtumat tulevat
callbackeina ja sovelluksen on palautettava kontrolli.

Vaihtoehdot:
- **(A) Takeover.** Init-vaiheessa Admiral ottaa ruudun ja IRQ:n haltuunsa ja
  pyörii kuten nyt; `EXIT()` palauttaa vektorit, ZP:n, $01:n ja sivut OS:lle.
  Utilityt ja hiiri eivät toimi Admiralin ollessa päällä. Halvin; vaatii
  varmistuksen, salliiko C64 OS tämän siististi.
- **(B) Sisäkkäinen event-pumppu.** `kbd_getchar_spin` kutsuu OS:n
  "käsittele tapahtumat" -rutiinia loopissa, ja layerin key-handler tallettaa
  näppäimen jonoon. Toimii vain, jos OS tarjoaa re-entrantin pumpun (todennä-
  köistä, koska pitkät operaatiot tarvitsevat sitä — tarkistettava).
- **(C) Korutiini.** Admiral ajetaan omalla HW-pino-segmentillä; yield/resume
  kopioi $0100-pinon osan puskuriin ja takaisin. Täysi C64 OS -kansalaisuus
  (valikot, Utilityt tulkin rinnalla). Suurin työ, mutta puhtain lopputulos.
  FS/RS ovat jo ohjelmistopinoja, joten vain HW-pino on ongelma.

### 3.6 Levy
Suorat KERNAL-kutsut toimivat, koska KERNAL on sisällä — mutta ohittavat
C64 OS:n polku-/osiokäsitteen ja saattavat sekoittaa OS:n käsityksen
avoimista kanavista. Ensimmäisessä vaiheessa riittää, että `LOAD/SAVE/DIR/RM`
kysyvät nykyisen hakemiston OS:ltä (file reference struct) ja jatkavat muuten
ennallaan. Admiralin oma oliograafin serialisointi säilyy sellaisenaan.

### 3.7 Build
Tarvitaan `#if C64OS`-käännösvariantti ja pakkaustyökalu, joka tuottaa
app-bundlen (`main` = koodi $0800:aan, `menu.m`, ikoni/asetukset).
`examples/*.admiral` säilyvät TYPE_STR-tietueina omassa hakemistossaan.

## 4. Suositeltu polku

**Vaihe 0 — selvitys (päiviä).** Lue Programmer's Guiden luvut 2 ja 4 sekä
liitteet: ZP-varaukset, `pgalloc`-maksimi, layer-API, näppäintapahtumat,
onko "exclusive/takeover"-tilaa tai re-entranttia event-pumppua. Kokeile
VICEssä minimi-app, joka kirjoittaa OS:n tekstiruutuun ja lukee näppäimen.

**Vaihe 1 — Hosted takeover (viikkoja).** `#if C64OS`: heapin rajat
`pgalloc`ilta, steady state `$36`, ei omia vektoreita, `sei` FP-envelopessa,
ZP-swap init/exit, ruutu OS:n puskuriin, `EXIT()` palauttaa OS:lle. Tulos:
Admiral käynnistyy C64 OS:n App Launcherista ja palaa siihen; ~10 KB heap.

**Vaihe 2 — Natiivi kansalainen (kuukausia).** Korutiinipohjainen kontrolli
(3.5 C), File/Edit-valikot, Utilityt tulkin rinnalla, OS:n tiedostoviitteet.

## 5. Johtopäätös

Teknisesti mahdollista. Vaihe 1 on realistinen ilman rakenteellisia
muutoksia tulkkiin: kaikki vaadittu on jo eristetty (`defs.asm`-vakiot,
`keyboard.asm`, `screen.asm`, `basic_op`-envelope, `disk.asm`-wrapperit).
Kaksi asiaa ratkaisee hyödyn: **(1) heap kutistuu ~30 → ~10 KB**, mikä rajaa
ajettavat ohjelmat pieniksi, ja **(2) blokkaava syöttömalli** estää aidon
yhteistoiminnan ilman korutiinia. Jos 10 KB ei riitä, koko idea kannattaa
arvioida uudelleen ennen vaihetta 2.

## 6. Avoimet kysymykset
1. C64 OS:n ZP-varaukset sovellukselle (liite).
2. Onko takeover-/exclusive-tila tai re-entrantti event-pumppu olemassa?
3. Suurin yhtenäinen `pgalloc`-lohko käytännössä (fragmentaatio Utilityjen jälkeen)?
4. OS-merkistön ja PETSCII-screen-codejen vastaavuus.
5. Sallitaanko sovelluksen vaihtaa $01 (`$37`) hetkellisesti?

## Lähteet
- https://c64os.com/post/rethinkingthememmap
- https://www.c64os.com/post/?p=25 (Application Loading)
- https://c64os.com/c64os/programmersguide/usingkernal
- https://c64os.com/post/utilities_menu
- https://c64os.com/c64os/usersguide/prgalias
- https://c64os.com/c64os/usersguide/applauncher

## 7. Rajattu tahtotila (2026-08-30)

- Tavoite: mahdollisimman natiivi C64 OS -versio → vaihtoehto 3.5 (C):
  korutiini, screen layer, OS:n tapahtumat, OS:n tiedostoviitteet.
- Toiminnallisuudesta tingitään reilusti; kaikki grafiikka (BITMAP,
  HEAP_HANDLE_START_GFX, CALL-asm-laajennukset) jää pois C64 OS -targetista.

## 8. Versionhallinta

Ei pitkäikäistä haaraa eikä forkkia. Portti tehdään samaan repoon ja
päähaaraan erillisenä build-targetina:

- `src/admiral.asm` (native) ja `src/admiral_c64os.asm` (C64 OS, `#define C64OS`)
  importtaavat saman ytimen.
- Alustariippuva koodi `src/platform/native/` ja `src/platform/c64os/`:
  näppäimistö, ruutu, keskeytykset, pankitus, levy-wrapperit, muistirajat,
  exit. Ydin kutsuu vain alustarajapintaa; `#if C64OS` sallitaan ytimessä
  vain kourallisessa paikkoja.
- `make` rakentaa molemmat targetit, `make test` ajaa py65-testit molemmille
  (uusi fixture stubbaa C64 OS -ytimen hyppytaulun kuten `KernalDiskMock`).

Järjestys: (1) alustakerroksen eriytys ja heap-rajojen parametrisointi
päähaarassa ilman C64 OS -koodia, natiivi-PRG samankokoisena; (2) portti
lyhytikäisessä `feature/c64os-port`-haarassa, merge heti kun assembloituu
ja testit läpi; (3) rinnakkaistyöhön `git worktree`, ei haaroja.

Forkki vasta jos ytimeen tarvitaan natiivin kanssa yhteensopimattomia
ratkaisuja (esim. sivutettu heap) ja `#if`-lohkot ytimessä karkaavat käsistä.

## 9. Vaihe 0 — tulokset (2026-08-30)

Lähde: Programmer's Guide luvut 2, 4 (kaikki 10 moduulia), 6 (+ class
reference), 8 (tutoriaalit 1–2) sekä liitteet ja aiheeseen liittyvät
blogikirjoitukset. Paikalliset kopiot scratchpadissa (`usingkernal_*.txt`,
`usingtoolkit_*.txt`, `writingapp_*.txt`, `gists/`).

### 9.1 Korjattu muistikartta (v1.0, guide luku 2)

| Alue          | Sivut | Sisältö |
|---------------|-------|---------|
| $0000-$08FF   | 9     | Workspace: ZP, HW-pino, järjestelmämuuttujat, 150 t sivukartta, **4 sivun ruutupuskuri** |
| $0900-$82FF   | 122   | **Heap — ainoa sovellustila, 30,5 KB** (jaettu `mapsys`-sivujen kanssa). `main.o` assembloidaan `$0900`:aan (`appbase`). IDE64: yläraja $7FFF |
| $8300-$A2FF   | 32    | Toolkit-luokat (muistissa pysyvät 9) |
| $A300-$CFFF   | 45    | C64 OS KERNAL, kasvaa alaspäin $CFFF:stä |
| $D000-$DFFF   | 16    | Video-RAM I/O:n alla (merkistö, VIC-matriisi, väripuskuri); VIC bank 0 |
| $E000-$FF3F   | 32    | Yksi 8 KB lohko: Utility **tai** bitmap **tai** sovelluksen puskuri (`himemuse`) |
| $FF40-$FFFF   |       | Hiiriosoitin-spritet + CPU-vektorit (ROM ulkona) — ei kosketa |

Seuraus: aiempi arvio "42 KB sovellustilaa, ~10 KB heap" oli liian
optimistinen. Admiralin koodi (30,7 KB) **täyttää yksin koko heapin**.

### 9.2 Muistibudjetti C64 OS -targetille

Nykyinen koodijakauma (symbolitiedostosta): builtins 6,0 KB, parser 5,5,
lexer 2,6, edit 2,1, array 1,7, disk 1,7, float 1,1, admiral+repl 1,6,
alloc/gc/assign/statics/val/dict ~4,0, tst 0,7, loput ~3,6.

Karsittavissa/korvattavissa OS:n primitiiveillä (arvio):
- grafiikka-builtinit, `BITMAP`, `PEEK/POKE/CALL`-laajennukset, `MEM`-
  kikkailu, NMI-banneri, keyboard.asm, IRQ-koodi: ~1,5 KB
- disk.asm → `fopen/fread/fwrite/fclose` + fref (tietueiden serialisointi
  säilyy): -1,0 KB
- screen.asm / print-polut ennallaan (kirjoittavat omaan layer-puskuriin)
- editori (2,1 KB): Toolkitissa **ei ole** dokumentoitua editoitavaa
  monirivistä luokkaa (`tktext` on vain näyttö, `tkinput` yksirivinen,
  `tktarea` mainittu mutta dokumentoimaton) → oma editori säilyy.
Realistinen koodi: **~27 KB** → heapissa jää ~3 KB + pinot 2 KB. Ei riitä.

Ainoa toimiva budjetti: Admiralin **oma heap $E000-$FF3F -lohkoon (8 KB,
`himemuse=hmembuff`)** + heapin jämät. Hinta: Utilityt eivät voi olla auki
Admiralin ajon aikana (OS pyytää sulkemaan; sama rajoite kuin bitmapilla).
Jos Utility-yhteensopivuus on pakollinen, koodi olisi saatava ~20 KB:iin —
se tarkoittaisi builtin-joukon ja parserin selvää karsimista.

### 9.3 Hyödynnettävät primitiivit (vastaus kysymykseen "ikkunointi tms.")

Ei ikkunointia (ei window manageria), mutta seuraavat ovat suoraan käyttö-
kelpoisia:

| Tarve            | C64 OS -primitiivi | Käyttö Admiralissa |
|------------------|--------------------|--------------------|
| Ruutu            | screen layer (`layerpush`, struct: sldraw/slmous/slkcmd/slkprt/slindx) + oma `pgalloc`-puskuri (4 sivua merkit + 4 väri) + `ctx2scr` + `markredraw` | `SCREEN_BASE` = oma layer-puskuri; `screen.asm` kirjoittaa siihen kuten nyt; draw-vektori kutsuu `ctx2scr`. Näkyy menun/Utilityjen alla oikein. |
| Näppäimistö      | `readkprnt` (tulostuvat + kursori/RETURN/DEL/HOME), `readkcmd` (modifier-yhdistelmät, F-näppäimet) | layer-käsittelijät työntävät jonoon → korutiinin resume. F1/F3/F5/F7 tulevat kcmd-tapahtumina. |
| Valikot          | `menu.m` + `mc_menq`/`mc_mnu` -viestit | File: Load/Save/Run/Go Home; Edit: Cut/Copy/Paste; Utilities-valikko ilmaiseksi. |
| Leikepöytä       | `clipin`/`clipout` (tekstiä), `copen/cread/cwrite/cclose` | Editoriin C=X/C/V, REPL:iin liitä. Aito natiivietu. |
| Tiedostot        | fref-struct, `fopen`(ff_r/ff_w/ff_p), `fread`/`fwrite` (inline-argumentit tai manuaalinen CHKIN/CHRIN `freflfn`:llä), `fclose`, `getsfref`, `frefcvt` | `LOAD/SAVE/DIR/RM` OS:n polku-/osiokäsitteellä; CMD/SD2IEC-hakemistot. |
| Muisti           | `pgalloc(#mapapp)`/`pgfree`, `malloc/free`, `himemuse` | pinot ja heap init-aikana; `mapapp`-sivut vapautuvat automaattisesti quitissa. |
| Tila/kiire       | `setflags rcpubusy`, statusrivi `mc_stptr` | "RUNNING"-indikaattori pitkissä ohjelmissa. |
| Ajastimet        | `timeque`, `msgapp` | ei tarvita korutiinilla. |
| Toolkit          | TKView-aliluokka: vain `draw` toteutettava; `keypress`/`dokeyeqv` fokusoituneelle näkymälle; TKScroll ympärille | Vaihtoehto suoralle layer-puskurille: REPL "terminaali-widget". Ei välttämätön, maksaa ~200 t + luokkakoodin. |
| FP               | BASIC ROM sallittu "carefully and temporarily"; OS itse tekee FP:n näin (`float.s`) | `basic_op` säilyy; `$37` piilottaa Toolkit+KERNAL-ytimen ($8300-$BFFF) → `sei/cli` envelopeen. |

Ei ole: yield/event-pump-kutsua (vahvistettu), editoitavaa monirivistä
tekstiluokkaa, modaalista syöttödialogia, IRQ-hookkia sovellukselle.

### 9.4 Vastaukset luvun 6 avoimiin kysymyksiin

1. **ZP.** Ei virallista karttaa, mutta rutiinidokumenteista koottu unioni
   OS:n käyttämistä soluista $00-$4F: `$02-04 $07-09 $0c $17-27 $2b-34
   $39-3e $45-46 $4e-53`. Vapaita scratch-soluja sovellukselle: `$fb-$fe`.
   **ISR:n sisällä** käytetään vain `$02, $d8, $d9` (ajastimet) ja `$c6,
   $cb` (näppäimistö). → Admiralin `FSP=$02` **on siirrettävä**; muu
   $02-$4A-lohko hoidetaan swapilla (ks. 9.5).
2. **Takeover / yield.** Ei yieldiä. Takeover on de facto sallittu
   (FLI-katselijan malli: korvaa ISR, palauta `confirq`:lla), mutta ei
   natiivi. → korutiini (C) on ainoa natiivi reitti — vahvistettu.
3. **pgalloc.** Allokoi ylhäältä alas heapista; `main.o` alhaalla. Sovellus
   saa käytännössä kaiken $0900-$82FF:stä miinus `mapsys`-sivut (OS,
   valikot, ladatut kirjastot). Tarkka luku mitattava (`memfree`).
4. **Merkistö.** Draw-konteksti tukee `d_petscr`-muunnosta; suoraan
   puskuriin kirjoitettaessa Admiralin `petscii_to_screen_code` toimii,
   mutta OS-merkistö sisältää UI-glyfejä koodeissa $00-$14 ja varaa
   $77-$7F/$F7-$FF ikoneille. Screen code `$60` on läpinäkyvä `ctx2scr`:ssä.
5. **$01.** Sallittu hetkellisesti. ISR patchaa ROMin itse sisään/ulos, joten
   `$36`↔`$37` ei vaadi IRQ-maskausta *paitsi* kun $37 peittää OS-ytimen —
   siis aina Admiralin tapauksessa → `sei`.

### 9.5 Tarkennettu arkkitehtuuri (natiivi)

```
main.o @ $0900:  vektoritaulu (init, msgcmd, willquit, freeze, thaw)
init:  initextern → pgalloc(layer-puskurit 8 sivua, FS 4, RS 4, ZP-swap 1)
       → himemuse := hmembuff, heap $E000-$FF3F (+ heapin jämät)
       → layerpush(admiral_layer) → käynnistä korutiini "repl_main"
event-loop (OS)                 korutiini (Admiral)
  slkprt/slkcmd: readk* → jono   kbd_getchar: jono tyhjä → YIELD
  → RESUME jos jonossa            ...tulkki pyörii, kirjoittaa layer-puskuriin,
  sldraw: ctx2scr(layer)          kutsuu markredraw...
  mc_mnu: Load/Save/Run/Home      OS-kutsut (fopen…) bracketattu ZP-save/restore
YIELD/RESUME: swap ZP $02-$4A (Admiral-lohko ↔ OS-lohko), vaihda SP
  HW-pino jaetaan: OS $01FF↓ (matala), Admiral S=$7F↓ (128 t).
  Admiral tekee jo `tsx` REPL:ssä ja `txs` virheessä → yhteensopiva.
willquit: pgfree ei-mapapp, himemuse := hmemfree.
```

Korutiini ei kopioi pinoa lainkaan: koska loader tyhjentää HW-pinon ennen
`evtloop`ia ja OS-puolen syvyys on pieni (Toolkit push/pull 11 t/taso),
Admiralille voidaan antaa pinon alempi puolisko. ZP-swap on ~75 tavua
kumpaankin suuntaan per näppäintapahtuma — mitätön.

### 9.6 Päätös seuraavasta askeleesta

1. Mittaa todellinen vapaa heap C64 OS 1.0x:ssä VICEssä (`memfree`
   Hello World -sovelluksesta) — ratkaisee, onko 27 KB koodi + $E000-heap
   riittävä vai pitääkö karsia 20 KB:iin.
2. Minimi-app: layer-puskuri + `readkprnt`-kaiku + korutiini-yield/resume
   ZP-swapilla ja jaetulla pinolla. Todentaa 9.5:n oletukset (ISR:n
   ZP-käyttö, pinojako, `$37`+`sei`).
3. Vasta sitten alustakerroksen eriytys päähaarassa (luku 8).

Tarvitaan: C64 OS -lisenssi/levykuva (`//os/h/`, `//os/s/`, `//os/tk/h/`
-headerit ovat vain jakelussa — metodi- ja property-offsetit eivät ole
verkossa) sekä TMPx tai KickAssembler-käännös headereista.

## 10. Päätös (2026-08-30)

**Ei portata.** Ratkaiseva syy: C64 OS 1.0:n sovellustila on $0900-$82FF
(30,5 KB, jaettu OS:n kanssa) ja Admiralin koodi on 30,7 KB. Natiivi versio
vaatisi koodin karsimista ~20 KB:iin tai heapin sijoittamista $E000-lohkoon
Utility-yhteensopivuuden kustannuksella — kummassakin tapauksessa tulos olisi
selvästi nykyistä suppeampi tulkki ilman vastaavaa hyötyä.

Selvityksestä jää käyttökelpoista muuhun kehitykseen:
- moduulikohtainen koodijakauma (9.2) — pohja koodin kutistamiselle;
- alustakerroksen rajapinta (luku 8) on hyödyllinen refaktorointi myös
  ilman C64 OS -targetia (esim. tulevaa VIC bank 3 -siirtoa varten).

Uudelleenarviointi vain, jos C64 OS:n muistikartta muuttuu (esim. blogin
"rethinking the memory map" -suunnitelma toteutuu: sovellustila $0500-$AFFF)
tai Admiralin koodi kutistuu ≤ 20 KB:iin.
