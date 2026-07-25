#!/usr/bin/env bash
# Backfills two standard metadata fields into photos this app processed before
# the app learned to write them, so already-organized files match what a fresh
# Process & Move would now produce:
#
#   1. Focus distance   Olympus:FocusDistance (MakerNote, only exiftool/this app
#                       read it) -> EXIF:SubjectDistance + XMP-exif:SubjectDistance,
#                       the standard fields Lightroom / Photo Mechanic / DxO show.
#   2. Alt text         the existing caption (XMP-dc:Description, or IPTC:Caption-
#                       Abstract) -> XMP-iptcCore:AltTextAccessibility.
#
# Both passes only fill a gap: a file that already has SubjectDistance / alt text
# is left untouched, so this is safe to re-run and won't clobber anything the app
# or you already set. Focus distances that read blank, "inf" (focused at infinity)
# or 0 are skipped, matching the app's own rule.
#
# Usage:
#   scripts/backfill-standard-metadata.sh [--apply] [--force-focus] [--year YYYY] <directory>
#
#   (no --apply)   Dry run: lists what each pass WOULD change, writes nothing.
#   --apply        Perform the writes.
#   --force-focus  Overwrite an existing EXIF:SubjectDistance with the camera's own
#                  Olympus:FocusDistance (when that reads as a usable finite distance;
#                  blank/inf/0 are still skipped). The focus pass skips files that
#                  already have a SubjectDistance by default, so this is the escape
#                  hatch for replacing a value you don't trust from another tool.
#                  Note: DxO PhotoLab already copies the real FocusDistance into
#                  SubjectDistance on export, only substituting a placeholder for
#                  infinity-focus frames (which the inf guard skips anyway) -- so on
#                  DxO exports this flag typically rewrites identical values for no
#                  gain (and forces a full re-upload per file). Prefer the default.
#   --year YYYY    Restrict to files whose DateTimeOriginal is that year
#                  (the library folders carry no year, so this filters by capture
#                  date; omit to process every file under <directory>).
#
# Recurses into <directory> and processes .orf/.jpg/.jpeg. Writes metadata only —
# image data is never rewritten — but --apply uses -overwrite_original (no per-file
# backup), so have your usual library backup (Time Machine etc.) in place first.

set -euo pipefail

apply=0
force_focus=0
year=""
target=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --force-focus) force_focus=1; shift ;;
    --year) year="${2:?--year needs a value, e.g. --year 2026}"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^set -euo/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) target="$1"; shift ;;
  esac
done

: "${target:?usage: backfill-standard-metadata.sh [--apply] [--force-focus] [--year YYYY] <directory>}"

common=(-r -ext orf -ext jpg -ext jpeg)
if [ -n "$year" ]; then
  common+=(-if "\$DateTimeOriginal =~ /^$year/")
fi

# The focus value must be a usable finite distance regardless of mode (blank/inf/0
# are meaningless, matching the app's rule).
focus_if='$Olympus:FocusDistance and $Olympus:FocusDistance ne "inf" and ($Olympus:FocusDistance#) > 0'
# Default: also skip files that already carry a SubjectDistance, so a re-run is a
# no-op and another tool's value is never overwritten. --force-focus drops that
# guard so the camera value wins.
if [ "$force_focus" -eq 0 ]; then
  focus_if="not \$ExifIFD:SubjectDistance and $focus_if"
fi
alt_if='not $XMP:AltTextAccessibility and ($XMP-dc:Description or $IPTC:Caption-Abstract)'

# exiftool exits 2 when every file fails the -if condition -- for a gap-fill pass
# that just means "nothing to backfill", not an error. Under `set -e` an unhandled
# exit 2 from the focus pass would abort the script before the alt-text pass runs,
# so tolerate it here while still letting a genuine failure (exit 1) stop the run.
run_exiftool() {
  exiftool "$@" || [ $? -eq 2 ]
}

if [ "$apply" -eq 0 ]; then
  echo "== DRY RUN (no files will be changed) =="
  echo
  echo "Pass 1 - focus distance -> EXIF:SubjectDistance:"
  exiftool "${common[@]}" -if "$focus_if" \
    -p '  $directory/$filename  (FocusDistance $Olympus:FocusDistance)' -q "$target" 2>/dev/null || true
  echo
  echo "Pass 2 - caption -> XMP-iptcCore:AltTextAccessibility:"
  exiftool "${common[@]}" -if "$alt_if" \
    -p '  $directory/$filename' -q "$target" 2>/dev/null || true
  echo
  echo "Re-run with --apply to write these changes."
  exit 0
fi

echo "== Pass 1: focus distance -> EXIF:SubjectDistance =="
run_exiftool "${common[@]}" -overwrite_original -if "$focus_if" \
  '-EXIF:SubjectDistance<Olympus:FocusDistance#' \
  '-XMP-exif:SubjectDistance<Olympus:FocusDistance#' \
  "$target"

echo "== Pass 2: caption -> XMP-iptcCore:AltTextAccessibility =="
# Both source assignments are listed; exiftool uses the last one that has a value,
# so XMP-dc:Description (the app's canonical caption field) wins when present.
run_exiftool "${common[@]}" -overwrite_original -if "$alt_if" \
  '-XMP-iptcCore:AltTextAccessibility<IPTC:Caption-Abstract' \
  '-XMP-iptcCore:AltTextAccessibility<XMP-dc:Description' \
  "$target"
