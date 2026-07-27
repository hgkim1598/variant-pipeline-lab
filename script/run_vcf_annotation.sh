#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PARENT="${BASH_SOURCE[0]%/*}"
[[ "${SCRIPT_PARENT}" != "${BASH_SOURCE[0]}" ]] || SCRIPT_PARENT="."
SCRIPT_DIR="$(cd -- "${SCRIPT_PARENT}" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/run_vcf_annotation.py"
PYTHON_BIN="${PYTHON_BIN:-python}"

usage() {
  cat <<'EOF'
VariantScope Bash entrypoint

Usage:
  run_vcf_annotation.sh INPUT_VCF REGION OUTPUT_PREFIX [CLINVAR_VCF] [OPTIONS]

REGION:
  panel                    Resolve every gene in the selected PanelApp panel
  all                      Process the entire input VCF
  chr17:43044292-43170245  Process one explicit genomic interval

Example:
  bash scripts/run_vcf_annotation.sh \
    data/raw/vcf/HG002_GRCh38_v5.0q_smvar.vcf.gz \
    panel \
    results/annotation/HG002_HBOC_panel_final \
    data/annotation/clinvar/clinvar_GRCh38_chr.vcf.gz \
    --assembly GRCh38 \
    --filter-preset pass-only \
    --panel-id 635 \
    --panel-version 3.0 \
    --panel-confidence green \
    --vep-mode rest

All options after the positional arguments are passed to run_vcf_annotation.py.
Use --help to see the complete option list.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf 'ERROR: VariantScope stopped at Bash line %s (exit code %s).\n' \
    "${BASH_LINENO[0]:-unknown}" "${exit_code}" >&2
  exit "${exit_code}"
}
trap on_error ERR

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  exec "${PYTHON_BIN}" "${PYTHON_SCRIPT}" --help
fi

[[ $# -ge 3 ]] || {
  usage >&2
  fail "INPUT_VCF, REGION, and OUTPUT_PREFIX are required"
}

command -v "${PYTHON_BIN}" >/dev/null 2>&1 \
  || fail "Python was not found: ${PYTHON_BIN}"
command -v bcftools >/dev/null 2>&1 \
  || fail "bcftools was not found; activate the variantscope conda environment"
[[ -f "${PYTHON_SCRIPT}" ]] \
  || fail "Python analysis core was not found: ${PYTHON_SCRIPT}"

INPUT_VCF=$1
REGION=$2
OUTPUT_PREFIX=$3

[[ -f "${INPUT_VCF}" ]] || fail "input VCF was not found: ${INPUT_VCF}"
OUTPUT_DIR="${OUTPUT_PREFIX%/*}"
[[ "${OUTPUT_DIR}" != "${OUTPUT_PREFIX}" ]] || OUTPUT_DIR="."
mkdir -p -- "${OUTPUT_DIR}"

printf '%s\n' \
  "[Bash] VariantScope launcher" \
  "[Bash] Python core: ${PYTHON_SCRIPT}" \
  "[Bash] Input VCF: ${INPUT_VCF}" \
  "[Bash] Region mode: ${REGION}" \
  "[Bash] Output prefix: ${OUTPUT_PREFIX}"

printf '[Bash] Command:'
printf ' %q' "${PYTHON_BIN}" "${PYTHON_SCRIPT}" "$@"
printf '\n'

"${PYTHON_BIN}" "${PYTHON_SCRIPT}" "$@"

printf '%s\n' "[Bash] Completed successfully." "[Bash] Generated files:"
shopt -s nullglob
generated_files=("${OUTPUT_PREFIX}".*)
if [[ ${#generated_files[@]} -eq 0 ]]; then
  printf '  No files matched %s.*\n' "${OUTPUT_PREFIX}"
else
  printf '  %s\n' "${generated_files[@]}"
fi
