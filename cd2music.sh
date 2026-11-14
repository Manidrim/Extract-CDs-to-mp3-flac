#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

SECTOR=2352
LEADIN=150
SAMPLE_RATE=44100
CHANNELS=2
BITRATE_MP3=320
CR=$'\r'

ARTIST=""
ALBUM=""
TITLES_FILE=""
OUTDIR=""
TMP=""
DEV=""
UNMOUNTED=0
DD_EXTRA=""
TITLE_LIST=()
TNUM=()
TSTART=()
TLEN=()
NTRACKS=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'Erreur : %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage : ./cd2music.sh "Artiste" "Album" [titres.txt]

Extrait le CD audio présent dans le lecteur en FLAC (archivage) et
MP3 320 kbps, avec tags (artiste, album, numéro et titre de piste).

  titres.txt  fichier texte optionnel, un titre de piste par ligne ;
              sans fichier, les pistes s'appellent "Track 01", "Track 02", ...

Variables d'environnement :
  CD_DEVICE   périphérique à utiliser (ex. /dev/disk2), sinon détection auto
  KEEP_RAW=1  conserve l'image brute du CD (cd-raw.pcm) dans le dossier de sortie

Prérequis : macOS + brew install ffmpeg lame flac
EOF
}

cleanup() {
  rc=$?
  if [ "$UNMOUNTED" = "1" ] && [ -n "$DEV" ]; then
    drutil eject >/dev/null 2>&1 || diskutil eject "$DEV" >/dev/null 2>&1 || true
  fi
  [ -n "$TMP" ] && rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

sanitize() {
  printf '%s' "$1" | tr '/:' '--' | tr -d '\000-\037'
}

check_deps() {
  local c missing=0
  for c in drutil diskutil dd od ffmpeg flac lame; do
    if ! command -v "$c" >/dev/null 2>&1; then
      printf 'Manquant : %s\n' "$c" >&2
      missing=1
    fi
  done
  [ "$missing" = "0" ] || die "dépendances manquantes (brew install ffmpeg lame flac sur macOS)"
}

read_titles() {
  local file=$1 line n=0
  [ -f "$file" ] || die "fichier de titres introuvable : $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$CR"}
    TITLE_LIST[$n]=$line
    n=$((n + 1))
  done < "$file"
}

title_for() {
  local i=$1
  if [ "$i" -lt "${#TITLE_LIST[@]}" ] && [ -n "${TITLE_LIST[$i]}" ]; then
    printf '%s' "${TITLE_LIST[$i]}"
  else
    printf 'Track %02d' "$((i + 1))"
  fi
}

detect_device() {
  if [ -n "${CD_DEVICE:-}" ]; then
    DEV=$CD_DEVICE
    [ -e "$DEV" ] || die "périphérique introuvable : $DEV (variable CD_DEVICE)"
    return
  fi
  DEV=$(drutil status 2>/dev/null | sed -n 's/.*Name:[[:space:]]*//p' | awk '{print $1}' | head -n 1 || true)
  [ -n "$DEV" ] || die "aucun média détecté dans le lecteur optique (drutil status)"
}

mount_point() {
  local vol
  vol=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p' | head -n 1 | sed 's/\\040/ /g')
  if [ -z "$vol" ]; then
    vol=$(mount 2>/dev/null | grep -F "$DEV" | head -n 1 | sed -e 's/^[^ ]* on //' -e 's/ ([^)]*)$//' -e 's/\\040/ /g' || true)
  fi
  if [ -z "$vol" ] || [ ! -d "$vol" ]; then
    diskutil mountDisk "$DEV" >/dev/null 2>&1 || true
    vol=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/^ *Mount Point: *//p' | head -n 1 | sed 's/\\040/ /g')
  fi
  [ -n "$vol" ] && [ -d "$vol" ] || die "impossible de monter le CD ($DEV) pour lire sa table des matières"
  printf '%s' "$vol"
}

read_toc() {
  local vol=$1 f num pos len
  for f in "$vol"/track*.cda; do
    [ -e "$f" ] || die "aucun fichier .cda dans $vol : le média n'est pas un CD audio"
    num=$(od -An -tu1 -j22 -N1 "$f" | awk '{print $1}')
    pos=$(od -An -tu1 -j28 -N4 "$f" | awk '{print $1 + $2*256 + $3*65536 + $4*16777216}')
    len=$(od -An -tu1 -j32 -N4 "$f" | awk '{print $1 + $2*256 + $3*65536 + $4*16777216}')
    [ -n "$num" ] && [ -n "$pos" ] && [ -n "$len" ] || die "table des matières illisible : $f"
    [ "$len" -gt 0 ] || die "piste $num de longueur nulle : $f"
    TNUM[$NTRACKS]=$num
    TSTART[$NTRACKS]=$((pos + LEADIN))
    TLEN[$NTRACKS]=$len
    NTRACKS=$((NTRACKS + 1))
  done
  [ "$NTRACKS" -gt 0 ] || die "aucune piste audio trouvée"
}

dd_probe() {
  if dd if=/dev/zero of=/dev/null bs=1 count=0 iflag=fullblock status=progress 2>/dev/null; then
    DD_EXTRA="iflag=fullblock status=progress"
  elif dd if=/dev/zero of=/dev/null bs=1 count=0 iflag=fullblock 2>/dev/null; then
    DD_EXTRA="iflag=fullblock"
  else
    DD_EXTRA=""
  fi
}

main() {
  if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    usage
    exit 2
  fi
  ARTIST=$1
  ALBUM=$2
  TITLES_FILE=${3:-}
  [ -n "$ARTIST" ] || die "nom d'artiste vide"
  [ -n "$ALBUM" ] || die "nom d'album vide"
  [ "$(uname -s)" = "Darwin" ] || die "ce script cible macOS (drutil et diskutil requis)"

  check_deps
  [ -n "$TITLES_FILE" ] && read_titles "$TITLES_FILE"

  detect_device
  log "Lecteur détecté : $DEV"

  local vol
  vol=$(mount_point)
  log "CD monté sur : $vol"
  read_toc "$vol"
  log "$NTRACKS piste(s) audio détectée(s)"

  OUTDIR="$PWD/$(sanitize "$ARTIST") - $(sanitize "$ALBUM")"
  mkdir -p "$OUTDIR"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/cd2music.XXXXXXXX")

  log "Démontage du disque..."
  diskutil unmountDisk "$DEV" >/dev/null 2>&1 || diskutil unmount "$DEV" >/dev/null 2>&1 || true
  UNMOUNTED=1

  local rdev raw
  rdev="/dev/r${DEV#/dev/}"
  [ -e "$rdev" ] || rdev=$DEV
  raw="$TMP/cd.raw"

  dd_probe
  log "Extraction de l'audio brut (dd, secteurs de $SECTOR octets) depuis $rdev..."
  dd if="$rdev" of="$raw" bs=235200 conv=swab $DD_EXTRA

  local rawsize expected last
  rawsize=$(stat -f %z "$raw" 2>/dev/null || stat -c %s "$raw")
  last=$((NTRACKS - 1))
  expected=$(((TSTART[$last] + TLEN[$last]) * SECTOR))
  [ "$rawsize" -ge "$expected" ] || die "extraction incomplète : $rawsize octets lus, $expected attendus"

  log "Découpage des pistes et encodage (FLAC + MP3 ${BITRATE_MP3} kbps)..."
  local i num start len title san base
  for ((i = 0; i < NTRACKS; i++)); do
    num=${TNUM[$i]}
    start=${TSTART[$i]}
    len=${TLEN[$i]}
    title=$(title_for "$i")
    san=$(sanitize "$title")
    base="$OUTDIR/$(printf '%02d' "$num") - $san"
    log "[$((i + 1))/$NTRACKS] $title"
    dd if="$raw" of="$TMP/t.raw" bs=$SECTOR skip=$start count=$len $DD_EXTRA
    ffmpeg -hide_banner -loglevel error -y -f s16le -ar "$SAMPLE_RATE" -ac "$CHANNELS" -i "$TMP/t.raw" "$TMP/t.wav"
    flac -s -8 -f \
      --tag="TITLE=$title" \
      --tag="ARTIST=$ARTIST" \
      --tag="ALBUM=$ALBUM" \
      --tag="TRACKNUMBER=$num" \
      --tag="TRACKTOTAL=$NTRACKS" \
      -o "$base.flac" "$TMP/t.wav"
    lame -b "$BITRATE_MP3" --add-id3v2 \
      --tt "$title" \
      --ta "$ARTIST" \
      --tl "$ALBUM" \
      --tn "$num" \
      "$TMP/t.wav" "$base.mp3"
    flac -s -t "$base.flac"
    rm -f "$TMP/t.raw" "$TMP/t.wav"
  done

  if [ "${KEEP_RAW:-0}" = "1" ]; then
    mv "$raw" "$OUTDIR/cd-raw.pcm"
  else
    rm -f "$raw"
  fi

  log "Terminé : $NTRACKS piste(s) dans $OUTDIR (éjection du CD...)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
