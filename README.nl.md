# Rushes

[![Release](https://img.shields.io/github/v/release/Marukiee/Rushes?label=release)](https://github.com/Marukiee/Rushes/releases/latest)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#installeren)

[English](README.md) | Nederlands

**Een Mac-app voor je geheugenkaarten en je schijf met beeld.** Steek een geheugenkaart in je Mac met je schijf eraan. Rushes herkent allebei, laat zien wat er nieuw is op de kaart, laat je snel door de beelden kijken, kopieert wat je houdt (elk bestand teruggelezen en gecontroleerd) en vertelt later welke clips op je schijf in geen enkel DaVinci Resolve-project zitten, zodat je ruimte terugkrijgt.

Gemaakt voor een Sony-camera en een grote externe SSD, maar niets is eraan gebonden.

## Wat het doet

- **Herkent een kaart en je schijf.** Een klein glazen kaartje verschijnt in de hoek van je scherm: "SD 5 en 4TB SSD zijn erin, 212 nieuw, 96 GB". Je kiest of je eerst kijkt (standaard) of alles meteen kopieert
- **Kijkt snel door een kaart.** Miniaturen waar je met de muis doorheen veegt, beeld voor beeld zoals in DaVinci, een grote speler met J K L en beeldstappen, de eigen LUT van de camera op log-beeld, sterren, en Houden of Weglaten per clip. Zwarte of afgedekte clips, hele korte clips, onscherpe foto's en bijna-kopieën in een serie worden voorgesteld om weg te laten
- **Kopieert alleen wat je houdt.** Alles, alleen de video's of de foto's, de hele kaart of per dag. Wat je niet beoordeeld hebt blijft op de kaart voor de volgende keer, en elke keuze en ster wordt onthouden als de kaart terugkomt
- **Kopieert veilig.** De kaart wordt alleen gelezen. Tijdens het lezen wordt een checksum gemaakt, het bestand wordt onder een tijdelijke naam geschreven en pas hernoemd als het compleet is, en dan wordt het van de schijf teruggelezen en vergeleken. Een tweede kopie naar een andere schijf kan in dezelfde ronde. Elke map krijgt een lijst met checksums, zodat je hem een jaar later nog kunt controleren
- **Noemt mappen zoals jij dat doet.** `SD 1`, `SD 2`, `SD 3`, het volgende nummer vanzelf. Dezelfde kaart gaat terug in zijn eigen map. Geef een map achteraf een naam (`SD 5 Zweden`) en het nummer blijft
- **Leest je DaVinci Resolve-projecten.** Rechtstreeks uit de projectbestanden van de lokale database, dus Resolve hoeft niet open te staan. Elke clip op de schijf krijgt een label: in een project (met project en tijdlijn), alleen in een mediapool, misschien gebruikt, of niet gebruikt
- **Geeft ruimte terug.** Niet gebruikte clips gaan met één toets naar de prullenbak en de volgende clip opent vanzelf. Bij een clip die een project gebruikt vraagt hij eerst, en Ongedaan maken zet hem terug
- **Praat met Resolve.** Met Resolve Studio open komt nieuw beeld in een bin met de opnamedatum, en eventueel een tijdlijn in opnamevolgorde. Alles is in de instellingen uit te zetten
- **Zorgt voor zichzelf.** Een menubalk-app die bij het inloggen start, de Mac wakker houdt tijdens het kopiëren, vraagt of je echt wilt stoppen midden in een kopie, en zichzelf bijwerkt vanaf GitHub met een handtekeningcontrole

## Installeren

Je hebt macOS 26 of nieuwer en een Mac met Apple silicon nodig.

1. Download `Rushes-macOS.zip` van de [nieuwste release](https://github.com/Marukiee/Rushes/releases/latest), open hem en zet Rushes in Programma's.
2. Open Rushes. macOS weigert de eerste keer, omdat de app is ondertekend met een eigen certificaat en niet is genotariseerd door Apple. Klik met rechts op de app en kies Open, of ga naar Systeeminstellingen, Privacy en beveiliging en klik op "Toch openen". Dat doe je maar één keer.
3. De eerste keer dat een kaart wordt gelezen vraagt macOS om toegang tot externe volumes. Sta dat toe.

Daarna werkt Rushes zichzelf bij.

## Toetsen

De toetsen staan in de [Engelse README](README.md#keys-in-the-review). Hoe Rushes Resolve-projecten leest staat in [docs/HOW-IT-READS-RESOLVE.md](docs/HOW-IT-READS-RESOLVE.md) (Engels).

## Bouwen

Alleen de Command Line Tools zijn nodig, geen Xcode.

```sh
swift build                       # de app
swift run RushesChecks            # de controles
./scripts/build-macos.sh debug    # dist/Rushes Dev.app, een aparte app met eigen data
```

## Licentie

AGPL-3.0, zie [LICENSE](LICENSE). Gemaakt door Mark Maakt Media.
