# Extract-CDs-to-mp3-flac

`cd2music.sh` transforme ta discothèque de CD audio en fichiers numériques sur
macOS, en ligne de commande : chaque piste est extraite en **FLAC** (archivage
sans perte) et en **MP3 320 kbps** (qualité maximale), avec tags ID3/Vorbis
(artiste, album, numéro et titre de piste).

Depuis 2024, Homebrew ne distribue plus `cdparanoia` (plus maintenu), donc ce
script s'appuie uniquement sur les outils natifs de macOS — `drutil`,
`diskutil`, `dd`, `od` — plus `ffmpeg`, `lame` et `flac` pour l'encodage.

## Prérequis

- macOS (le script utilise `drutil`/`diskutil` et le système de fichiers `cddafs`)
- Un lecteur optique (USB ou interne)
- Homebrew :

```bash
brew install ffmpeg lame flac
```

## Installation

```bash
chmod +x cd2music.sh
```

## Utilisation

Insère un CD audio, puis lance :

```bash
./cd2music.sh "Nightwish" "Once" titres.txt
```

`titres.txt` est un fichier texte optionnel avec **un titre de piste par ligne**,
dans l'ordre du CD :

```text
Wish I Had an Angel
Nemo
Planet Hell
...
```

Sans fichier de titres, les pistes sont nommées `Track 01`, `Track 02`, etc.
(à renommer ensuite).

Les fichiers sont écrits dans un dossier `Artiste - Album/` créé dans le
répertoire courant :

```text
Nightwish - Once/
├── 01 - Wish I Had an Angel.flac
├── 01 - Wish I Had an Angel.mp3
├── 02 - Nemo.flac
├── 02 - Nemo.mp3
...
```

## Ce que fait le script

1. Détecte le lecteur et le média avec `drutil status` (ou `CD_DEVICE=/dev/diskN`).
2. Lit la table des matières du CD via les fichiers `trackNN.cda` exposés par
   macOS (`/Volumes/<CD>/`), parsés avec `od` : position et longueur de chaque
   piste en secteurs de 75 images/seconde.
3. Démonte le disque (`diskutil unmountDisk`) puis copie l'audio brut avec
   `dd` sur le périphérique brut (`/dev/rdiskN`, secteurs de 2352 octets,
   `conv=swab` pour obtenir du PCM 44,1 kHz 16 bits stéréo little-endian).
   C'est l'étape la plus longue (~5-15 min selon le lecteur).
4. Découpe chaque piste à sa position exacte dans l'image brute (la piste 1
   démarre au secteur absolu 150, soit 00:02:00 après le lead-in de 2 s).
5. Encode chaque piste avec `ffmpeg` (PCM → WAV), puis `flac -8` (FLAC) et
   `lame -b 320` (MP3 320 kbps), avec les tags.
6. Vérifie l'intégrité de chaque FLAC (`flac -t`) et éjecte le CD (`drutil eject`).

## Variables d'environnement

| Variable | Effet |
|---|---|
| `CD_DEVICE=/dev/diskN` | force le périphérique à utiliser (détection auto sinon) |
| `KEEP_RAW=1` | conserve l'image brute du CD (`cd-raw.pcm`) dans le dossier de sortie |

## Limites

- CD audio uniquement : la piste de données d'un CD « amélioré » (enhanced CD)
  n'est pas extraite.
- Le rip lit le média secteur par secteur sans correction d'erreur avancée
  (contrairement à `cdparanoia`/`whipper`) ; sur un disque rayé, certaines
  pistes pourront contenir des artefacts.
- Le décalage de lead-in de 150 secteurs (00:02:00) est le standard Red Book.
