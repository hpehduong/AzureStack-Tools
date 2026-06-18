#!/usr/bin/env bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# Script to calculate the hash of a PE file
#
# Usage:
#   ./calc_pe_hash.sh path/to/file.exe
#   ./calc_pe_hash.sh -h sha256 path/to/file.exe
#   ./calc_pe_hash.sh --keep -h sha1 path/to/file.exe
#
# Prints only the "Calculated message digest" (hex, uppercase) to stdout.
#
set -euo pipefail

show_usage() {
  echo "Usage: $0 [-h {md5|sha1|sha2|sha256|sha384|sha512}] [--keep] <file-to-sign>" >&2
  echo "  -h algorithm: Hash algorithm to use (default: sha256)" >&2
  echo "  --keep: Keep temporary files for debugging" >&2
  exit 1
}

KEEP="0"
HASH_ALGO="sha256"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h)
      if [[ $# -lt 2 ]]; then
        echo "Error: -h requires an argument" >&2
        show_usage
      fi
      HASH_ALGO="$2"
      shift 2
      ;;
    --keep)
      KEEP="1"
      shift
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      show_usage
      ;;
    *)
      # This should be the input file
      INPUT="$1"
      shift
      break
      ;;
  esac
done

# Validate we have an input file
if [[ -z "${INPUT:-}" ]]; then
  show_usage
fi

if [[ ! -f "$INPUT" ]]; then
  echo "Error: file not found: $INPUT" >&2
  exit 2
fi

# Check dependencies
command -v openssl >/dev/null 2>&1 || { echo "Error: openssl not found" >&2; exit 3; }
command -v osslsigncode >/dev/null 2>&1 || { echo "Error: osslsigncode not found" >&2; exit 3; }

# Work dirs and temp files
BASE_DIR="build/dummykeys"
mkdir -p "$BASE_DIR"

TMP_DIR="$(mktemp -d "${BASE_DIR}/tmp.XXXXXX")"
CERT="${TMP_DIR}/signing_cert.pem"
KEY="${TMP_DIR}/signing_key.pem"

# Preserve the original extension for the signed file (best-effort)
ext=""
fname="$(basename -- "$INPUT")"
case "$fname" in
  *.*) ext=".${fname##*.}";;
esac
SIGNED="${TMP_DIR}/signed${ext:-.bin}"

cleanup() {
  if [[ "$KEEP" != "1" ]]; then
    rm -rf -- "$TMP_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Generate ephemeral key+cert (PEM)
# You can adjust key size/days/subject as needed.
openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1
openssl req -new -x509 -key "$KEY" -out "$CERT" -days 3650 -subj "/CN=Dummy Ephemeral Signing Cert" >/dev/null 2>&1

# Sign the file with osslsigncode using specified hash algorithm
# -n sets a display name; adjust as desired. Suppress stdout chatter.
osslsigncode sign \
  -certs "$CERT" \
  -key "$KEY" \
  -h "$HASH_ALGO" \
  -n "Temporary Signed Artifact" \
  -in "$INPUT" \
  -out "$SIGNED" \
  >/dev/null

# Verify and extract the "Calculated message digest" line
# osslsigncode writes verification details to stdout; we parse the line.
VERIFY_OUT="$(osslsigncode verify "$SIGNED" 2>&1 || true)"

# Example line:
#   Calculated message digest  :  0FE6204CCE786C5F1DCD65E0BA91CD58759EDB8CB8E1880CE44236AF00F241B
HASH="$(printf '%s\n' "$VERIFY_OUT" \
  | awk -F': ' '/^[[:space:]]*Calculated message digest[[:space:]]*:/ {print $2}' \
  | tr -d '[:space:]' \
  | tr 'a-f' 'A-F')"

if [[ -z "$HASH" ]]; then
  echo "Error: could not extract Calculated message digest from verify output." >&2
  # For debugging, uncomment the next line:
  # printf 'Verify output:\n%s\n' "$VERIFY_OUT" >&2
  exit 4
fi

# Output only the hash
printf '%s\n' "$HASH"