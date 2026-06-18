#!/usr/bin/env bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# Script to calculate expected TPM PCR 4 value for a UKI boot
# PCR 4 tracks boot loader code and boot attempts
# Calculates for SHA1, SHA256, and SHA384 TPM banks
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALC_PE_HASH="$SCRIPT_DIR/calc_pe_hash.sh"
source "$SCRIPT_DIR/pcr_helpers.sh"

usage() {
  echo "Usage: $0 <uki.efi>"
  echo "  Calculates the expected PCR 4 value after booting the given UKI image"
  echo "  Outputs values for SHA1, SHA256, and SHA384 TPM banks"
  exit 1
}

[[ $# -eq 1 ]] || usage
UKI_FILE="$1"

if [[ ! -f "$UKI_FILE" ]]; then
  echo "Error: UKI file not found: $UKI_FILE" >&2
  exit 2
fi

check_pcr_dependencies

if [[ ! -x "$CALC_PE_HASH" ]]; then
  echo "Error: $CALC_PE_HASH not found or not executable" >&2
  exit 3
fi

BUILD_DIR="./build"
mkdir -p "$BUILD_DIR"

echo "[*] Calculating expected PCR 4 values for: $UKI_FILE"
echo

# Common data for all algorithms
EFI_STRING="Calling EFI Application from Boot Option"
ZERO_BYTES='\x00\x00\x00\x00'

# Extract kernel once (used by all algorithms)
KERNEL_FILE="$BUILD_DIR/kernel.efi"
echo "[*] Extracting kernel from UKI to: $KERNEL_FILE"
objcopy --dump-section .linux="$KERNEL_FILE" "$UKI_FILE" /dev/null || true

if [[ ! -f "$KERNEL_FILE" ]]; then
  echo "    Warning: Could not extract kernel from UKI (no .linux section?)" >&2
  HAVE_KERNEL=false
else
  echo "    Kernel extracted successfully"
  HAVE_KERNEL=true
fi
echo

# Calculate PCR 4 for each algorithm
for ALGO in sha1 sha256 sha384; do
  echo "=========================================="
  echo "Calculating PCR 4 for TPM bank: ${ALGO^^}"
  echo "=========================================="
  echo
  
  # Compute PE hashes with algorithm-specific authenticode hash
  echo "[*] Computing PE authenticode hashes with ${ALGO^^}..."
  UKI_HASH_HEX="$("$CALC_PE_HASH" -h "$ALGO" "$UKI_FILE")"
  echo "    UKI PE hash (${ALGO^^}): $UKI_HASH_HEX"
  
  if [[ "$HAVE_KERNEL" == true ]]; then
    KERNEL_HASH_HEX="$("$CALC_PE_HASH" -h "$ALGO" "$KERNEL_FILE")"
    echo "    Kernel PE hash (${ALGO^^}): $KERNEL_HASH_HEX"
  else
    KERNEL_HASH_HEX=""
  fi
  echo
  
  # Convert PE hashes to lowercase for consistency
  UKI_HASH_HEX="$(echo "$UKI_HASH_HEX" | tr 'A-F' 'a-f')"
  [[ -n "$KERNEL_HASH_HEX" ]] && KERNEL_HASH_HEX="$(echo "$KERNEL_HASH_HEX" | tr 'A-F' 'a-f')"
  
  # Step 1: Initialize PCR 4 to all zeros
  PCR4="$(get_zero_pcr "$ALGO")"
  echo "[1] Initial PCR 4 (all zeros):"
  echo "    $PCR4"
  echo
  
  # Step 2: Extend with hash of "Calling EFI Application from Boot Option"
  HASH1="$(hash_data "$EFI_STRING" "$ALGO")"
  echo "[2] ${ALGO^^}('$EFI_STRING'):"
  echo "    $HASH1"
  PCR4="$(extend_pcr "$PCR4" "$HASH1" "$ALGO")"
  echo "    PCR 4 after extend:"
  echo "    $PCR4"
  echo
  
  # Step 3: Extend with hash of 4 zero bytes
  HASH2="$(hash_binary "$ZERO_BYTES" "$ALGO")"
  echo "[3] ${ALGO^^}(4 zero bytes):"
  echo "    $HASH2"
  PCR4="$(extend_pcr "$PCR4" "$HASH2" "$ALGO")"
  echo "    PCR 4 after extend:"
  echo "    $PCR4"
  echo
  
  # Step 4: Extend with UKI PE hash (algorithm-specific authenticode hash)
  echo "[4] Extending with UKI PE hash (${ALGO^^} authenticode)"
  echo "    PE hash: $UKI_HASH_HEX"
  PCR4="$(extend_pcr "$PCR4" "$UKI_HASH_HEX" "$ALGO")"
  echo "    PCR 4 after extend:"
  echo "    $PCR4"
  echo
  
  # Step 5: Extend with kernel PE hash if available
  if [[ -n "$KERNEL_HASH_HEX" ]]; then
    echo "[5] Extending with kernel PE hash (${ALGO^^} authenticode)"
    echo "    PE hash: $KERNEL_HASH_HEX"
    PCR4="$(extend_pcr "$PCR4" "$KERNEL_HASH_HEX" "$ALGO")"
    echo "    PCR 4 after extend:"
    echo "    $PCR4"
    echo
  else
    echo "[5] Skipping kernel PE hash (extraction failed)"
    echo
  fi
  
  # Store final value for summary
  case "$ALGO" in
    sha1)   FINAL_SHA1="$PCR4" ;;
    sha256) FINAL_SHA256="$PCR4" ;;
    sha384) FINAL_SHA384="$PCR4" ;;
  esac
done

# Display summary
echo "=========================================="
echo "SUMMARY: Expected PCR 4 Values"
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