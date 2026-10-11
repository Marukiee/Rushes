# Releasing

1. Zet een kort item voor de nieuwe versie bovenaan `changelog.json` (Engels en Nederlands).
2. `swift build && swift run RushesChecks && python3 scripts/check-strings.py`, alles groen.
3. Commit met expliciete paden (nooit `git add -A`), push `main`.
4. Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`. Het versienummer komt uit de tag, je hoogt niets op.
5. De workflow `Release` bouwt op `macos-26`, tekent met het certificaat uit de secrets, controleert de bundel (versie, update-sleutel, de
   Resolve-script), zipt, tekent de zip met de Ed25519-sleutel en publiceert `Rushes-macOS.zip`, `.sha256` en `.sig`.
6. Controleer dat de release er staat met alle bestanden: `gh release view vX.Y.Z --repo Marukiee/Rushes`.

De app zoekt in `releases/latest` naar `Rushes-macOS.zip` met `.sha256` en `.sig`. Een versie met een streepje (`v1.2.0-rc1`) is een
voorlopige release en wordt niet aangeboden.

## Sleutels

Eenmalig, en doen niets als de sleutel al bestaat:

```sh
scripts/mac-signing.sh setup          # ~/keystores/rushes-mac-signing.p12
swift scripts/gen-update-key.swift    # ~/keystores/rushes-update-ed25519.secret, schrijft de publieke sleutel naar Resources/update-public-key.txt
scripts/setup-secrets.sh              # uploadt de drie secrets naar GitHub (alleen namen worden getoond)
```

Maak een back-up van `~/keystores`. Zonder de update-sleutel kan geen geïnstalleerde app nog bijwerken.
