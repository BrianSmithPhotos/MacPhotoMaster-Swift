#!/bin/sh
# Strips non-camera-generated metadata (AI-written captions/keywords/title and
# app-written GPS coordinates/altitude) from a folder of photos, restoring
# them to a camera-original state for realistic dev/test conditions against
# real SD card content.
#
# Deliberately left alone: GPSVersionID and a blank IFD0:ImageDescription —
# both are Olympus camera defaults present even on untouched RAW files, not
# something this app or its Python sibling wrote.
#
# Usage: scripts/strip-app-metadata.sh <directory>
#
# WARNING: uses -overwrite_original (no per-file backup) and modifies files
# in place, recursively. Only run against copies you have verified elsewhere.

set -eu

target="${1:?usage: strip-app-metadata.sh <directory>}"

exiftool -r -overwrite_original \
  -ext jpg -ext jpeg -ext orf \
  -IPTC:Keywords= \
  -IPTC:Caption-Abstract= \
  -IPTC:ObjectName= \
  -XMP-dc:Description= \
  -XMP-dc:Subject= \
  -XMP-dc:Title= \
  -GPSLatitude= -GPSLatitudeRef= \
  -GPSLongitude= -GPSLongitudeRef= \
  -GPSAltitude= -GPSAltitudeRef= \
  "$target"
