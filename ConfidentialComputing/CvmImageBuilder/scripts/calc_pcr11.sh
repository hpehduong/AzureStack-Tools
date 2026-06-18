#!/usr/bin/env bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# Script to calculate expected TPM PCR 11 value for a UKI boot
# PCR 11 tracks UKI section measurements during boot
# Each section contributes two extensions: hash(section_name) and hash(section_data)
# This ensures that all configuration used by the initramfs is measured into a combination
# of PCR4 and PCR11, with the bootloader components and kernel in PCR4 and the initramfs
# image, kernel command line and various other fields measured into PCR11.
#
# Note that this slightly differs from the standard UKI PCR11 measured boot calculation
# in that systemd events such as entering initrams and exiting initrams are not measured
# into PCR11. This is because these events do not extend the TCG log making it impossible
# for attestation services to correlate PCR11 with the TCG log when used. This does not
# affect the effectiveness of measured boot so long as there is no way for a user to
# run code between entering the initrams environment and leaving it - therefore the
# emergency recovery console must be disabled.
#

# Calculates for SHA1, SHA256, and SHA384 TPM banks
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pcr_helpers.sh"

# UKI sections measured in order (as per UAPI spec)
UKI_SECTIONS=(".linux" ".osrel" ".cmdline" ".initrd" ".uname" ".sbat")

usage() {
  echo "Usage: $0 <uki.efi>"
  echo "  Calculates the expected PCR 11 value after booting the given UKI image"
  echo "  Outputs values for SHA1, SHA256, and SHA384 TPM banks"
  echo ""
  echo "  The UKI sections measured in order are:"
  echo "    ${UKI_SECTIONS[*]}"
  exit 1
}

[[ $# -eq 1 ]] || usage
UKI_FILE="$1"

if [[ ! -f "$UKI_FILE" ]]; then
  echo "Error: UKI file not found: $UKI_FILE" >&2
  exit 2
fi

check_pcr_dependencies

# Use a temporary directory for extracted sections
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "[*] Calculating expected PCR 11 values for: $UKI_FILE"
echo

# Extract all sections from the UKI
echo "[*] Extracting UKI sections..."
declare -A SECTION_FILES
for section in "${UKI_SECTIONS[@]}"; do
  # Remove leading dot for filename
  section_name="${section#.}"
  section_file="$TEMP_DIR/uki_section_${section_name}.bin"
  
  # Extract the section using -O binary --only-section
  rm -f "$section_file"
  if objcopy -O binary --only-section="${section}" "$UKI_FILE" "$section_file" 2>/dev/null; then
    if [[ -s "$section_file" ]]; then
      SECTION_FILES["$section"]="$section_file"
      size=$(stat -c%s "$section_file" 2>/dev/null || stat -f%z "$section_file" 2>/dev/null)
      echo "    $section: extracted ($size bytes)"
    else
      echo "    $section: not present"
      rm -f "$section_file"
    fi
  else
    echo "    $section: not present"
    rm -f "$section_file"
  fi
done
echo

# Calculate PCR 11 for each algorithm
for ALGO in sha1 sha256 sha384; do
  echo "=========================================="
  echo "Calculating PCR 11 for TPM bank: ${ALGO^^}"
  echo "=========================================="
  echo
  
  # Step 1: Initialize PCR 11 to all zeros
  PCR11="$(get_zero_pcr "$ALGO")"
  echo "[*] Initial PCR 11 (all zeros):"
  echo "    $PCR11"
  echo
  
  step=1
  for section in "${UKI_SECTIONS[@]}"; do
    if [[ -v SECTION_FILES["$section"] ]]; then
      section_file="${SECTION_FILES[$section]}"
      
      echo "[$step] Processing section: $section"
      
      # Extend with hash of section name (including null terminator)
      name_hash="$(hash_section_name "$section" "$ALGO")"
      echo "    ${ALGO^^}('$section\\0'): $name_hash"
      PCR11="$(extend_pcr "$PCR11" "$name_hash" "$ALGO")"
      echo "    PCR 11 after name extend: $PCR11"
      
      # Extend with hash of section data
      data_hash="$(hash_file "$section_file" "$ALGO")"
      echo "    ${ALGO^^}(section data): $data_hash"
      PCR11="$(extend_pcr "$PCR11" "$data_hash" "$ALGO")"
      echo "    PCR 11 after data extend: $PCR11"
      echo
      
      step=$((step + 1))
    fi
  done
  
  # Store final value for summary
  case "$ALGO" in
    sha1)   FINAL_SHA1="$PCR11" ;;
    sha256) FINAL_SHA256="$PCR11" ;;
    sha384) FINAL_SHA384="$PCR11" ;;
  esac
done

# Display summary
echo "=========================================="
echo "SUMMARY: Expected PCR 11 Values"
echo "=========================================="
echo
echo "SHA1:   $FINAL_SHA1"
echo "SHA256: $FINAL_SHA256"
echo "SHA384: $FINAL_SHA384"
echo
SHA256_BASE64=$(echo -n "$FINAL_SHA256" | xxd -r -p | base64 -w 0)
echo "SHA256 (base64): $SHA256_BASE64"
echo
echo "=========================================="
