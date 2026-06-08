#!/usr/bin/env bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# Shared helper functions for TPM PCR calculation scripts.
# Source this file from other scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/pcr_helpers.sh"
#

# Guard against double-sourcing
[[ -n "${_PCR_HELPERS_LOADED:-}" ]] && return 0
_PCR_HELPERS_LOADED=1

# ---------------------------------------------------------------------------
# extend_pcr  -  PCR_new = Hash(PCR_old || event_data)
#
# Args: current_pcr_hex  data_to_extend_hex  algorithm
# ---------------------------------------------------------------------------
extend_pcr() {
  local current="$1"
  local data="$2"
  local algo="$3"

  local combined
  combined="$(printf '%s%s' "$current" "$data" | xxd -r -p | openssl dgst -"$algo" -binary | xxd -p -c 256)"
  echo "$combined"
}

# ---------------------------------------------------------------------------
# get_zero_pcr  -  Return an all-zeros PCR value (hex) for the given algorithm
#
# Args: algorithm  (sha1 | sha256 | sha384)
# ---------------------------------------------------------------------------
get_zero_pcr() {
  local algo="$1"
  case "$algo" in
    sha1)
      echo "0000000000000000000000000000000000000000"  # 20 bytes
      ;;
    sha256)
      echo "0000000000000000000000000000000000000000000000000000000000000000"  # 32 bytes
      ;;
    sha384)
      echo "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"  # 48 bytes
      ;;
    *)
      echo "Error: Unknown algorithm $algo" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# hash_data  -  Hash a plain string (no null terminator)
#
# Args: data_string  algorithm
# ---------------------------------------------------------------------------
hash_data() {
  local data="$1"
  local algo="$2"
  printf '%s' "$data" | openssl dgst -"$algo" -binary | xxd -p -c 256
}

# ---------------------------------------------------------------------------
# hash_binary  -  Hash literal bytes expressed as printf escape sequences
#                 (e.g. '\x00\x00\x00\x00')
#
# Args: escaped_bytes  algorithm
# ---------------------------------------------------------------------------
hash_binary() {
  local data="$1"
  local algo="$2"
  printf "$data" | openssl dgst -"$algo" -binary | xxd -p -c 256
}

# ---------------------------------------------------------------------------
# hash_section_name  -  Hash a section name string WITH a null terminator
#
# Args: name  algorithm
# ---------------------------------------------------------------------------
hash_section_name() {
  local name="$1"
  local algo="$2"
  printf '%s\0' "$name" | openssl dgst -"$algo" -binary | xxd -p -c 256
}

# ---------------------------------------------------------------------------
# hash_file  -  Hash the contents of a file
#
# Args: filepath  algorithm
# ---------------------------------------------------------------------------
hash_file() {
  local file="$1"
  local algo="$2"
  openssl dgst -"$algo" -binary "$file" | xxd -p -c 256
}

# ---------------------------------------------------------------------------
# check_pcr_dependencies  -  Verify required CLI tools are available
# ---------------------------------------------------------------------------
check_pcr_dependencies() {
  for cmd in openssl objcopy xxd; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd not found" >&2; exit 3; }
  done
}
