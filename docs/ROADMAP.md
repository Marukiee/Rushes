# Roadmap

Wat er nog kan komen. Nieuwe wensen komen hier eerst.

## Gevraagd, nog niet gebouwd

- **De gewone Rushes ziet de SD niet, Rushes Dev wel** (gemeld 2026-10-14, uitzoeken met een SD in de Mac). Vermoedens, in deze
  volgorde: de gewone app is 0.1.1 uit `~/Downloads`, en de kaartsleuf van de Mac wordt pas sinds 0.1.2 herkend. Hij staat daar met
  quarantaine, dus macOS start hem verplaatst (App Translocation) en de updater kan hem misschien niet vervangen: 0.1.3 werd wel
  gemeld maar niet geïnstalleerd. Of de toestemming voor verwisselbare schijven is voor `nl.markmaaktmedia.Rushes` niet gegeven.
  Eerst naar `/Applications` zetten en bijwerken, dan opnieuw proberen.

- Kaart wissen na een geslaagde controle (optie in de instellingen, standaard uit).
- Melding op de telefoon via Tandem als een import klaar is of de schijf vol raakt.

## Ideeën

- Proxies maken voor clips zonder camera-proxy (Blackmagic Proxy Generator staat op de Mac).
- Ploegen en locaties: een naam voorstellen voor een kaartmap uit de datums en de GPS van de foto's.
- Kleurlabels en sterren ook in Resolve zetten als clip color en rating bij het versturen.
- Een tweede back-up die later wordt bijgewerkt als de tweede schijf er pas later aan komt.
- Gebruik van Resolve voor het open project ook live lezen (via de scripting-API), zodat een niet opgeslagen project meetelt.
- Ondersteuning van PostgreSQL-databases van Resolve.
- Controle van de manifests op een schema (een keer per maand), met een melding bij een afwijking.
- Siri en Opdrachten: "importeer de kaart".

## Gedaan in 0.2.0

Standaard alleen kopiëren wat behouden is, keuze voor video's, foto's of allebei, menu per dag (selecteren, behouden,
overslaan, kopiëren, terugzetten met bevestiging), R en een tweede klik om terug te zetten, keuzes en sterren in de ledger
(ook als de kaart terugkomt), overgeslagen clips opruimen uit de map op de schijf, voortgang in het venster met gekopieerd en
gecontroleerd apart, de fout bij een tweede dag.

## Gedaan in 0.1.0

Systeemzijbalk en werkbalk in Liquid Glass, hover-skimmen van clips,
herkenning van kaart en schijf met een zwevend kaartje, bekijken met suggesties en LUT, kopiëren met controle en tweede kopie,
`SD n`-mappen, bibliotheek met Resolve-gebruik, opruimen met prullenbak en ongedaan, bins met datum, timeline, hernoemen met
relink, integriteitscontrole, geschiedenis met grafiek, menubalk, updates.
