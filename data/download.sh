#!/usr/bin/env bash
#
# download.sh — fetch the NHTSA Office of Defects Investigation (ODI) flat files
#               and their data dictionaries into data/raw/.
#
# WHERE THIS FITS IN THE DEMO
# ---------------------------
# This is step 1 of 4. It pulls the *publisher's* raw artefacts:
#
#   1. data/download.sh            <-- you are here
#   2. sql/01_schema.sql           physical DDL, cryptic column names preserved
#   3. data/load_nhtsa.py          COPY the flat files into odi.cmpl / rcl / inv
#   4. scripts/generate_comments.py  dictionaries -> sql/02_comments.sql
#
# The dictionaries (CMPL.txt / RCL.txt / INV.txt) are not optional extras: they are
# the *source of truth* for every COMMENT ON statement in the demo. When someone in
# the room asks "did you tune the comments to make Text-to-SQL work?", the answer is
# this script plus generate_comments.py plus a public URL. Nothing is hand-written.
#
# HOST NOTE — READ BEFORE THE DEMO
# --------------------------------
# NHTSA publishes the same files from two hosts:
#
#   * https://static.nhtsa.gov/odi/ffdd/...          (CDN, fast, VERIFIED 2026-08-07)
#   * https://www-odi.nhtsa.dot.gov/downloads/...    (legacy origin, genuinely slow)
#
# The legacy origin is the URL quoted in most documentation, but it is slow enough to
# take several minutes for FLAT_CMPL.zip and it did not resolve at all from the
# build sandbox on 2026-08-07. We therefore default to the CDN and keep the legacy
# origin available via BASE_URL= for the day the CDN path changes.
#
# Expect the download to be slow on the legacy origin. That is normal, not a hang.
# Every curl below uses `-C -` so an interrupted transfer resumes instead of
# restarting -- which is the difference between a 20-second retry and a 10-minute one
# when the hotel wifi drops during setup.
#
# FILE LAYOUT NOTE
# ----------------
# Recalls are published as TWO files, split at model year 2010:
#   FLAT_RCL_PRE_2010.zip  and  FLAT_RCL_POST_2010.zip
# There is no combined FLAT_RCL.zip on the CDN (it 404s). The loader concatenates
# whichever parts are present. POST_2010 alone is plenty for the demo.
#
# Usage:
#   ./data/download.sh            # skip anything already downloaded
#   ./data/download.sh --force    # re-download everything
#
set -euo pipefail

BASE_URL="${BASE_URL:-https://static.nhtsa.gov/odi/ffdd}"

# Resolve paths relative to this script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_DIR="${RAW_DIR:-$SCRIPT_DIR/raw}"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg (try --force or --help)" >&2; exit 2 ;;
  esac
done

mkdir -p "$RAW_DIR"

# ---------------------------------------------------------------------------
# What to fetch.  "<remote-path>|<local-filename>|<description>"
# ---------------------------------------------------------------------------
ITEMS=(
  "cmpl/CMPL.txt|CMPL.txt|Complaints data dictionary (source of COMMENT ON text)"
  "rcl/RCL.txt|RCL.txt|Recalls data dictionary"
  "inv/INV.txt|INV.txt|Investigations data dictionary"
  "cmpl/FLAT_CMPL.zip|FLAT_CMPL.zip|Complaints flat file (~370 MB zipped, ~1.5 GB raw)"
  "rcl/FLAT_RCL_POST_2010.zip|FLAT_RCL_POST_2010.zip|Recalls flat file, 2010 onward"
  "rcl/FLAT_RCL_PRE_2010.zip|FLAT_RCL_PRE_2010.zip|Recalls flat file, before 2010"
  "inv/FLAT_INV.zip|FLAT_INV.zip|Investigations flat file"
)

human() {
  # Portable byte formatter: no `numfmt` on macOS by default.
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB", u, " "); i=1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

size_of() {
  # `stat` flags differ between GNU and BSD; try both.
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

echo "NHTSA ODI flat file download"
echo "  base url : $BASE_URL"
echo "  target   : $RAW_DIR"
echo "  force    : $([ "$FORCE" -eq 1 ] && echo yes || echo no)"
echo

DOWNLOADED=0
SKIPPED=0

for item in "${ITEMS[@]}"; do
  IFS='|' read -r remote local desc <<< "$item"
  dest="$RAW_DIR/$local"

  if [[ -s "$dest" && "$FORCE" -eq 0 ]]; then
    echo "  skip     $local  ($(human "$(size_of "$dest")")) — already present, use --force to refetch"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  [[ "$FORCE" -eq 1 ]] && rm -f "$dest"

  echo "  fetch    $local — $desc"
  # -f  fail on HTTP >=400 (so we never write an HTML error page as a .zip)
  # -L  follow redirects
  # --retry / --retry-delay  survive NHTSA's intermittent 5xx
  # -C - resume a partial transfer rather than starting over
  # --max-time 1800  the legacy origin really is this slow; this is not a hang
  curl -fL \
       --retry 3 --retry-delay 5 --retry-connrefused \
       --connect-timeout 30 --max-time 1800 \
       -C - \
       --progress-bar \
       -o "$dest" \
       "$BASE_URL/$remote"

  DOWNLOADED=$((DOWNLOADED + 1))
done

echo
echo "Unzipping archives into $RAW_DIR"
shopt -s nullglob
for zip in "$RAW_DIR"/*.zip; do
  echo "  unzip    $(basename "$zip")"
  # -o overwrite silently, -q quiet: re-running must be idempotent.
  unzip -o -q "$zip" -d "$RAW_DIR"
done
shopt -u nullglob

# ---------------------------------------------------------------------------
# Summary. Print byte sizes so the presenter can see at a glance that a file
# is not a truncated 4 KB HTML error page.
# ---------------------------------------------------------------------------
echo
echo "======================================================================"
echo " Downloaded: $DOWNLOADED    Skipped: $SKIPPED"
echo "======================================================================"
printf " %-34s %14s  %s\n" "FILE" "BYTES" "SIZE"
echo "----------------------------------------------------------------------"
for f in "$RAW_DIR"/*; do
  [[ -f "$f" ]] || continue
  bytes="$(size_of "$f")"
  printf " %-34s %14s  %s\n" "$(basename "$f")" "$bytes" "$(human "$bytes")"
done
echo "----------------------------------------------------------------------"
echo
echo "Sanity check — expected raw text files (line counts as of 2026-08-07):"
echo "  FLAT_CMPL.txt            ~2.23 M lines, 51 tab-separated fields"
echo "  FLAT_RCL_POST_2010.txt   ~244 K lines,  29 tab-separated fields"
echo "  FLAT_RCL_PRE_2010.txt    ~82 K lines,   29 tab-separated fields"
echo "  FLAT_INV.txt             ~154 K lines,  11 tab-separated fields"
echo
echo "If a .txt is missing or a field count differs, STOP — do not load."
echo "load_nhtsa.py will refuse the load and tell you what to fix."
echo
echo "Next:  psql \"\$DEMO_DSN\" -f sql/01_schema.sql"
echo "       python3 data/load_nhtsa.py --dsn \"\$DEMO_DSN\" --subset 250000"
