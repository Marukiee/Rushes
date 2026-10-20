# Rushes, working notes

Vaste afspraken voor dit project. Lees dit voordat je iets aanpast.

## Schrijfstijl

- **Nooit het lange streepje** (em-dash), ook geen en-dash als koppelteken. Gebruik een gewone komma, een punt, of haakjes. Dit geldt
  overal: code, comments, commits, README, UI-teksten, en antwoorden in de chat.
- Geen AI-riedels. Kort houden. Comments leggen uit **waarom**, niet wat.
- Engels is de taal van de code en de sleutel van elke tekst. Nederlands staat in `Resources/nl.lproj/Localizable.strings`.

## Wat dit is

Een Mac-app (SwiftUI, Liquid Glass, macOS 26) die een geheugenkaart en een SSD herkent, de kaart laat doorkijken, kopieert met
controle, en bijhoudt welke clips in DaVinci Resolve-projecten worden gebruikt.

```
Sources/RushesKit      logica zonder venster: ledger, kopieerder, Resolve-database lezen, padsleutels, planner
Sources/Rushes         de app: modellen, schermen, updater
Sources/RushesChecks   de controles (een gewoon programma, want Swift Testing en XCTest vragen een volledige Xcode)
Resources              Info.plist, nl.lproj, resolve_bridge.py, update-public-key.txt
scripts                bouwen, tekenen, releasen, teksten
```

## Ontwerpbesluiten die niet opnieuw ter discussie staan

- **De kaart wordt alleen gelezen.** Niets op de kaart wordt veranderd of gewist. Wissen na controle staat op de roadmap, niet erin.
  Eén uitzondering, als de gebruiker erom vraagt: sterren of een label op de kaart zetten (`CardMarker`). Dat gaat in een XMP-sidecar
  naast het bestand (`DSC0001.xmp`), nooit in het origineel, want naam, grootte en tijd zijn hoe Rushes een bestand herkent.
- **Elk bestand wordt gecontroleerd.** SHA-256 tijdens het lezen, schrijven onder `.rushes-part`, hernoemen, terugleze van de schijf zelf
  (`F_NOCACHE`) en vergelijken. Een kopie telt pas als ze klopt.
- **Bestanden worden herkend op naam, grootte en tijd**, niet op naam alleen. Een kaart die is geformatteerd begint bij C0001
  opnieuw. Wat de gebruiker heeft overgeslagen wordt onthouden en niet opnieuw aangeboden.
- **Het kaartnummer is de identiteit van een map.** `SD 5` blijft `SD 5`, ook als er woorden achter komen. Resolve-paden worden
  op kaartnummer plus pad binnen de kaart vergeleken (`PathKeys`), zodat een andere mount, een Linux-pad of een hernoemde map
  nog klopt. Zelfde bestandsnaam zonder pad dat past is "misschien gebruikt" en nooit een zekerheid.
- **Resolve wordt offline gelezen.** `Project.db` wordt gekopieerd en de kopie wordt gelezen. Resolve hoeft niet open en wordt niet
  gestoord. Schrijven (bins, importeren, relinken) gaat via `Resources/resolve_bridge.py` en de scripting-API van Resolve Studio.
- **Alleen wat gekozen is wordt gekopieerd** (standaard). Niet beoordeeld blijft op de kaart en wordt niet als overgeslagen onthouden.
  Elke keuze en ster op een kaart staat in de ledger als `card|<fingerprint>` en gaat mee naar de map op de schijf (`leftOutOnCard`).
- **Niets wordt echt verwijderd.** Alles gaat naar de prullenbak, met Ongedaan. Een clip die een project gebruikt vraagt eerst.
- **Een proxy van de camera heeft de look al.** De LUT gaat alleen over het origineel (S-Log3). Zie `PlayerController`.
- **Foto's tellen niet mee in ruimtewinst** tenzij de gebruiker dat aanzet, want Resolve is zelden waar foto's worden gebruikt.

## Designtaal

Zelfde taal als Tandem en MarkMaaktAI (`github.com/Marukiee/Tandem`, `.../MarkMaaktAI`). Liquid Glass: `glassEffect` alleen op wat
zweeft (werkbalken, knoppen, de zwevende kaart, de afspeelbalk), inhoud staat op een gewoon vlak (`surface`). Beweging is spring-
gebaseerd (`Animation.rushes`, `.rushesSpringy`, `.rushesBouncy`), kleur en doorzichtigheid gaan met een tween (`.rushesFade`). Twee tinten:
indigo en roze. Groen is behouden, rood is overslaan, oranje is een suggestie.

**Consistentie:** zelfde vlak, maat, vorm, hoverlabel en uitlijning als de buren. Kijk eerst welk onderdeel op dezelfde pagina hetzelfde
doet en hergebruik dat.

## Designregels (Liquid Glass, macOS 26)

De app houdt zich aan Apple's regels voor de nieuwe look. Wie iets toevoegt doet dat ook.

- **Glas is voor de bediening, niet voor de inhoud.** Werkbalk, zijbalk, zwevende balken (importbalk, afspeelbalk over een video, het
  kaartje in de hoek) zijn glas. Kaarten, rijen, koppen en het raster staan op gewone vlakken (`surface`, `.regularMaterial` voor een
  vastgeplakte kop). Nooit glas op glas: binnen een glazen balk staan platte knoppen.
- **Systeemonderdelen waar het kan.** `List` als zijbalk (de SD-mappen zijn rijen onder Bibliotheek), `.toolbar` met `ToolbarItemGroup` en
  `ToolbarSpacer`, `navigationTitle` en `navigationSubtitle`, `.bordered`/`.borderedProminent` voor knoppen in de inhoud. Zelf getekend is
  alleen wat het systeem niet heeft: `GlassSegmented` (glazen keuzebalk met een lens die schuift), de hover-speler, de verdictknoppen.
- **Eén raster.** Alle maten komen uit `Space` (4, 8, 12, 16, 24) en de hoeken uit `Metrics` (concentrisch). Kleuren zijn semantisch
  (`primary`, `secondary`), het enige merk is indigo als accent en roos voor ruimte die vrij kan. Kleur betekent iets: groen behouden,
  rood overslaan, oranje suggestie. Tekst en pictogrammen in de merktinten gaan via `Palette.accent` en `Palette.roseInk`, die in licht en
  donker leesbaar zijn.
- **Geen lege ruimte.** De kolom naast het raster is boven en onder gevuld: beeld, keuzebalk, details, "Hierna". Een knop is nooit
  afgekapt (`ActionButton` heeft zijn natuurlijke breedte, rijen gaan door of staan onder elkaar via `ButtonRow`).
- **Echte screenshots** met `scripts/screenshot.sh` (alleen het eigen venster, via `screencapture -l`). Kijk altijd in licht én donker.

## Techniek

- Bundle-id `nl.markmaaktmedia.Rushes` (debug: `.Rushes.dev`, data in `Application Support/Rushes-Dev`). Minimaal macOS 26, arm64.
- Bouwen zonder Xcode: `swift build` met de Command Line Tools. `@State` is een macro in de nieuwste SDK en de plugin zit alleen in
  Xcode, dus overal `@LocalState` (zie `Theme.swift`). `@Observable` werkt wel.
- GitHub: `Marukiee/Rushes`, publiek, anders geeft de API 404 en werkt de update-check niet zonder token.

## Signing en updates

- **Mac-certificaat** `~/keystores/rushes-mac-signing.p12` (identiteit "Rushes Signing"), een zelfgemaakt certificaat. Zonder notarisatie vraagt
  de eerste installatie eenmalig "Toch openen". `scripts/mac-signing.sh setup` maakt het, doet niets als het er al is.
- **Update-sleutel (Ed25519)** privé in `~/keystores/rushes-update-ed25519.secret`, publiek in `Resources/update-public-key.txt` en in de app.
  `swift scripts/gen-update-key.swift` maakt hem, doet niets als hij er al is.
- **GitHub-secrets:** `MACOS_CERT_P12_B64`, `MACOS_CERT_PASSWORD`, `RUSHES_UPDATE_ED25519_SECRET`, uploaden met `scripts/setup-secrets.sh`.
- De app controleert een update op SHA-256, op de Ed25519-handtekening, en op dezelfde signing-identiteit als de draaiende app.

**Maak een back-up van `~/keystores`.** Zonder de update-sleutel accepteert geen geïnstalleerde app nog een update, en zonder het
certificaat vragen alle rechten opnieuw om toestemming.

## Releasen

Alles groen, dan taggen (`vX.Y.Z`). Het versienummer komt uit de tag. `changelog.json` krijgt eerst een kort item (Engels en Nederlands).
CI bouwt, tekent, controleert de bundel en publiceert `Rushes-macOS.zip` met `.sha256` en `.sig`. Zie `docs/RELEASING.md`.

## Werkwijze

- Fase 1 vragen stellen, fase 2 doorbouwen zonder tussentijds te stoppen. Bij twijfel kiezen, doorbouwen en achteraf zeggen wat je koos.
- Nieuwe wensen op `docs/ROADMAP.md` zetten.
- Nooit `git add -A` met half af werk.

## Bouwen, testen en draaien

- `swift build`, dan `swift run RushesChecks` (checks van de kit, ook tegen de echte Resolve-database als die er is).
- `swift run RushesChecks usage "/Volumes/<schijf>/SD 4"` toont hoe de projecten van Resolve de bestanden van een map gebruiken.
- `./scripts/build-macos.sh debug` geeft `dist/Rushes Dev.app`. Start die met `open -n` en `--env`, of rechtstreeks voor een logboek.
- De debug-build leest omgevingsvariabelen (alleen als `RUSHES_DEBUG_DIR` gezet is): `RUSHES_DEBUG_CARD=<map>` en `RUSHES_DEBUG_DEST=<map>`
  laten mappen een kaart en een schijf spelen, `RUSHES_DEBUG_PAGE`, `RUSHES_DEBUG_ACTIONS` (een script als `skip:0,keep:1,import,wait:8,snapshot`),
  `RUSHES_DEBUG_FLAT_GLASS` (glas als vlak, zodat tekst leesbaar is), `RUSHES_DEBUG_APPEARANCE=dark|light`, `RUSHES_DEBUG_HOLD_HOVER` (een hover-voorbeeld blijft op het beeld onder de aanwijzer staan, zodat een screenshot elke keer hetzelfde moment toont). SIGUSR1 schrijft PNG's van de vensters.
  Echte schermopnames van de Mac mogen niet.
- Teksten: `python3 scripts/check-strings.py` controleert dat elke tekst in de code een Nederlandse vertaling heeft. De tabel wordt gemaakt met
  `python3 scripts/strings/gen.py scripts/strings` uit `scripts/strings/nl1.py` en `nl2.py` (voegt de %lld- en %@-spelling toe en de %%-spelling).
  Met `-AppleLanguages "(nl)" -NSShowNonLocalizedStrings YES` staat een niet vertaalde tekst in hoofdletters.
- Raak nooit een netwerkschijf aan zonder alarm: `perl -e 'alarm N; exec @ARGV' ...`.
