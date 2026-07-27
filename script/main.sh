#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

# ============================================================
# Sarek-style samplesheet QC + Alignment pipeline
#
# Input CSV required columns:
#   patient,sample,lane,fastq_1,fastq_2
# Optional columns:
#   sex,status
#
# Main workflow:
#   samplesheet validation
#   -> reference index preparation
#   -> lane-level FastQC
#   -> lane-level BWA-MEM + coordinate sort
#   -> sample-level lane merge
#   -> BAM index / flagstat / idxstats / stats
#   -> MultiQC (optional)
# ============================================================

SCRIPT_NAME=$(basename "$0")
SCRIPT_VERSION="1.0.0"

INPUT_CSV=""
REFERENCE=""
OUTDIR=""
THREADS=4
PLATFORM="ILLUMINA"
RUN_FASTQC=true
RUN_MULTIQC=true
CHECK_GZIP=false
FORCE=false
KEEP_LANE_BAM=true

TMP_FILES=()
CURRENT_STEP="initialization"

usage() {
    cat <<EOF
Usage:
  bash $SCRIPT_NAME \\
    --input input.csv \\
    --reference /absolute/path/reference.fa \\
    --outdir /absolute/path/results \\
    [options]

Required:
  --input FILE          Sarek-style CSV samplesheet
  --reference FILE      Reference FASTA
  --outdir DIR          Output directory

Options:
  --threads INT         Threads used by BWA/samtools (default: 4)
  --platform STRING     Read-group PL value (default: ILLUMINA)
  --skip-fastqc         Skip FastQC
  --skip-multiqc        Skip MultiQC
  --check-gzip          Run full gzip integrity test on every FASTQ
  --remove-lane-bam     Remove lane BAMs after successful sample merge
  --force               Recreate existing outputs
  -h, --help            Show this help

Samplesheet columns:
  Required: patient,sample,lane,fastq_1,fastq_2
  Optional: sex,status

Example:
  bash $SCRIPT_NAME \\
    --input input.csv \\
    --reference \"\$HOME/projects/refs/GRCh38/Homo_sapiens_assembly38.fasta\" \\
    --outdir \"\$HOME/projects/results/qc_alignment\" \\
    --threads 4
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[%s] [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
    printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    local command=${2:-unknown}
    command=${command//$'\n'/ }
    if (( ${#command} > 240 )); then
        command="${command:0:240}..."
    fi

    printf '\n[%s] [ERROR] Pipeline failed.\n' "$(date '+%Y-%m-%d %H:%M:%S')" >&2
    printf '[ERROR] Step    : %s\n' "$CURRENT_STEP" >&2
    printf '[ERROR] Line    : %s\n' "$line_no" >&2
    printf '[ERROR] Command : %s\n' "$command" >&2
    printf '[ERROR] Exit    : %s\n' "$exit_code" >&2

    for path in "${TMP_FILES[@]:-}"; do
        [[ -n "$path" && -e "$path" ]] && rm -f -- "$path"
    done

    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap 'for path in "${TMP_FILES[@]:-}"; do [[ -n "$path" && -e "$path" ]] && rm -f -- "$path"; done' EXIT

require_value() {
    local option=$1
    local value=${2:-}
    [[ -n "$value" ]] || die "$option requires a value."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)
            require_value "$1" "${2:-}"
            INPUT_CSV=$2
            shift 2
            ;;
        --reference)
            require_value "$1" "${2:-}"
            REFERENCE=$2
            shift 2
            ;;
        --outdir)
            require_value "$1" "${2:-}"
            OUTDIR=$2
            shift 2
            ;;
        --threads)
            require_value "$1" "${2:-}"
            THREADS=$2
            shift 2
            ;;
        --platform)
            require_value "$1" "${2:-}"
            PLATFORM=$2
            shift 2
            ;;
        --skip-fastqc)
            RUN_FASTQC=false
            shift
            ;;
        --skip-multiqc)
            RUN_MULTIQC=false
            shift
            ;;
        --check-gzip)
            CHECK_GZIP=true
            shift
            ;;
        --remove-lane-bam)
            KEEP_LANE_BAM=false
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ -n "$INPUT_CSV" ]] || { usage >&2; die "--input is required."; }
[[ -n "$REFERENCE" ]] || { usage >&2; die "--reference is required."; }
[[ -n "$OUTDIR" ]] || { usage >&2; die "--outdir is required."; }
[[ "$THREADS" =~ ^[1-9][0-9]*$ ]] || die "--threads must be a positive integer: $THREADS"
[[ "$PLATFORM" =~ ^[A-Za-z0-9._-]+$ ]] || die "--platform contains invalid characters: $PLATFORM"

command -v python3 >/dev/null 2>&1 || die "Required tool not found in PATH: python3"

# Resolve top-level paths before creating output directories.
INPUT_CSV=$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$INPUT_CSV")
REFERENCE=$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$REFERENCE")
OUTDIR=$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$OUTDIR")

[[ -f "$INPUT_CSV" ]] || die "Input CSV not found: $INPUT_CSV"
[[ -r "$INPUT_CSV" ]] || die "Input CSV is not readable: $INPUT_CSV"
[[ -s "$INPUT_CSV" ]] || die "Input CSV is empty: $INPUT_CSV"
[[ -f "$REFERENCE" ]] || die "Reference FASTA not found: $REFERENCE"
[[ -r "$REFERENCE" ]] || die "Reference FASTA is not readable: $REFERENCE"
[[ -s "$REFERENCE" ]] || die "Reference FASTA is empty: $REFERENCE"

RUN_INFO_DIR="$OUTDIR/run_info"
QC_FASTQC_DIR="$OUTDIR/qc/fastqc"
QC_MULTIQC_DIR="$OUTDIR/qc/multiqc"
ALIGN_LANE_DIR="$OUTDIR/alignment/lane_bam"
ALIGN_SAMPLE_DIR="$OUTDIR/alignment/sample_bam"
LOG_DIR="$OUTDIR/logs"
REF_LOG_DIR="$LOG_DIR/reference"
FASTQC_LOG_DIR="$LOG_DIR/fastqc"
ALIGN_LOG_DIR="$LOG_DIR/alignment"
MERGE_LOG_DIR="$LOG_DIR/merge"

mkdir -p \
    "$RUN_INFO_DIR" \
    "$QC_FASTQC_DIR" \
    "$QC_MULTIQC_DIR" \
    "$ALIGN_LANE_DIR" \
    "$ALIGN_SAMPLE_DIR" \
    "$REF_LOG_DIR" \
    "$FASTQC_LOG_DIR" \
    "$ALIGN_LOG_DIR" \
    "$MERGE_LOG_DIR"

PIPELINE_LOG="$LOG_DIR/pipeline.log"
exec > >(tee -a "$PIPELINE_LOG") 2>&1

log "============================================================"
log "Sarek-style QC + Alignment pipeline v$SCRIPT_VERSION"
log "Input CSV : $INPUT_CSV"
log "Reference : $REFERENCE"
log "Outdir    : $OUTDIR"
log "Threads   : $THREADS"
log "Platform  : $PLATFORM"
log "============================================================"

CURRENT_STEP="checking required tools"
REQUIRED_TOOLS=(python3 bwa samtools)
if [[ "$RUN_FASTQC" == true ]]; then
    REQUIRED_TOOLS+=(fastqc)
fi
if [[ "$CHECK_GZIP" == true ]]; then
    REQUIRED_TOOLS+=(gzip)
fi

for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found in PATH: $tool"
done

if [[ "$RUN_MULTIQC" == true ]] && ! command -v multiqc >/dev/null 2>&1; then
    warn "MultiQC is not installed. MultiQC will be skipped."
    RUN_MULTIQC=false
fi

{
    echo "pipeline_version=$SCRIPT_VERSION"
    echo "run_started=$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "input_csv=$INPUT_CSV"
    echo "reference=$REFERENCE"
    echo "outdir=$OUTDIR"
    echo "threads=$THREADS"
    echo "platform=$PLATFORM"
    echo "run_fastqc=$RUN_FASTQC"
    echo "run_multiqc=$RUN_MULTIQC"
    echo "check_gzip=$CHECK_GZIP"
    echo "force=$FORCE"
    echo "bwa_version=$(bwa 2>&1 | head -n 3 | tr '\n' ' ' || true)"
    echo "samtools_version=$(samtools --version | head -n 1)"
    [[ "$RUN_FASTQC" == true ]] && echo "fastqc_version=$(fastqc --version 2>&1 | head -n 1)"
    [[ "$RUN_MULTIQC" == true ]] && echo "multiqc_version=$(multiqc --version 2>&1 | head -n 1)"
} > "$RUN_INFO_DIR/software_versions.txt"

# ------------------------------------------------------------
# Validate and normalize Sarek-style CSV with Python's csv module.
# Relative FASTQ paths are resolved relative to the CSV directory.
# ------------------------------------------------------------
CURRENT_STEP="validating input samplesheet"
VALIDATED_CSV="$RUN_INFO_DIR/input.validated.csv"
MANIFEST_TSV="$RUN_INFO_DIR/input.manifest.tsv"
SAMPLE_METADATA_TSV="$RUN_INFO_DIR/sample_metadata.tsv"

python3 - "$INPUT_CSV" "$VALIDATED_CSV" "$MANIFEST_TSV" "$SAMPLE_METADATA_TSV" <<'PY'
import csv
import os
import re
import sys
from collections import OrderedDict
from pathlib import Path

input_csv = Path(sys.argv[1])
validated_csv = Path(sys.argv[2])
manifest_tsv = Path(sys.argv[3])
sample_metadata_tsv = Path(sys.argv[4])

required = ["patient", "sample", "lane", "fastq_1", "fastq_2"]
known = {"patient", "sex", "status", "sample", "lane", "fastq_1", "fastq_2"}
id_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
fastq_re = re.compile(r"\.(fastq|fq)\.gz$", re.IGNORECASE)

errors = []
warnings = []
rows = []
seen_keys = set()
seen_fastqs = {}
sample_to_patient = {}
sample_metadata = OrderedDict()
patient_sex = {}
base_dir = input_csv.parent.resolve()

try:
    handle = input_csv.open("r", encoding="utf-8-sig", newline="")
except UnicodeDecodeError as exc:
    print(f"[ERROR] Samplesheet is not valid UTF-8: {exc}", file=sys.stderr)
    sys.exit(2)

with handle:
    reader = csv.DictReader(handle)
    if reader.fieldnames is None:
        errors.append("Header row is missing.")
    else:
        original_headers = reader.fieldnames
        headers = [h.strip() if h is not None else "" for h in original_headers]

        if len(headers) != len(set(headers)):
            errors.append(f"Duplicate column names found: {headers}")

        if any(not h for h in headers):
            errors.append("One or more column names are blank.")

        missing = [name for name in required if name not in headers]
        if missing:
            errors.append("Missing required columns: " + ", ".join(missing))

        unknown = [name for name in headers if name not in known]
        if unknown:
            warnings.append("Unknown columns will be ignored: " + ", ".join(unknown))

        # Map stripped header names back into DictReader rows.
        header_map = dict(zip(original_headers, headers))

        for csv_line, raw in enumerate(reader, start=2):
            if None in raw:
                errors.append(f"Line {csv_line}: too many comma-separated fields.")
                continue

            row = {}
            for original_name, value in raw.items():
                normalized_name = header_map.get(original_name, original_name)
                row[normalized_name] = (value or "").strip()

            if not any(row.values()):
                warnings.append(f"Line {csv_line}: blank row skipped.")
                continue

            patient = row.get("patient", "")
            sample = row.get("sample", "")
            lane = row.get("lane", "")
            sex = row.get("sex", "") or "NA"
            status = row.get("status", "") or "0"
            fq1_raw = row.get("fastq_1", "")
            fq2_raw = row.get("fastq_2", "")

            for field_name, value in (("patient", patient), ("sample", sample), ("lane", lane)):
                if not value:
                    errors.append(f"Line {csv_line}: '{field_name}' is empty.")
                elif not id_re.fullmatch(value):
                    errors.append(
                        f"Line {csv_line}: invalid {field_name} '{value}'. "
                        "Use only letters, numbers, dot, underscore, and hyphen; do not use spaces or slashes."
                    )

            if status not in {"0", "1"}:
                errors.append(f"Line {csv_line}: status must be 0 (normal) or 1 (tumor), found '{status}'.")

            if not fq1_raw:
                errors.append(f"Line {csv_line}: fastq_1 is empty.")
            if not fq2_raw:
                errors.append(f"Line {csv_line}: fastq_2 is empty.")
            if not fq1_raw or not fq2_raw:
                continue

            def resolve_path(raw_path: str) -> Path:
                path = Path(os.path.expanduser(raw_path))
                if not path.is_absolute():
                    path = base_dir / path
                return path.resolve()

            fq1 = resolve_path(fq1_raw)
            fq2 = resolve_path(fq2_raw)

            for label, path in (("fastq_1", fq1), ("fastq_2", fq2)):
                if not fastq_re.search(path.name):
                    errors.append(
                        f"Line {csv_line}: {label} must end in .fastq.gz or .fq.gz: {path}"
                    )
                if not path.exists():
                    errors.append(f"Line {csv_line}: {label} does not exist: {path}")
                elif not path.is_file():
                    errors.append(f"Line {csv_line}: {label} is not a regular file: {path}")
                elif not os.access(path, os.R_OK):
                    errors.append(f"Line {csv_line}: {label} is not readable: {path}")
                elif path.stat().st_size == 0:
                    errors.append(f"Line {csv_line}: {label} is empty: {path}")
                else:
                    # Cheap gzip signature check. Full decompression is optional in the Bash layer.
                    try:
                        with path.open("rb") as fh:
                            magic = fh.read(2)
                        if magic != b"\x1f\x8b":
                            errors.append(f"Line {csv_line}: {label} is not a gzip file: {path}")
                    except OSError as exc:
                        errors.append(f"Line {csv_line}: cannot inspect {label}: {path}: {exc}")

            if fq1 == fq2:
                errors.append(f"Line {csv_line}: fastq_1 and fastq_2 point to the same file: {fq1}")

            key = (patient, sample, lane)
            if key in seen_keys:
                errors.append(
                    f"Line {csv_line}: duplicate patient/sample/lane combination: "
                    f"{patient}/{sample}/{lane}"
                )
            seen_keys.add(key)

            previous_patient = sample_to_patient.get(sample)
            if previous_patient is not None and previous_patient != patient:
                errors.append(
                    f"Line {csv_line}: sample '{sample}' is assigned to multiple patients: "
                    f"'{previous_patient}' and '{patient}'."
                )
            sample_to_patient[sample] = patient

            current_meta = (patient, sex, status)
            previous_meta = sample_metadata.get(sample)
            if previous_meta is not None and previous_meta != current_meta:
                errors.append(
                    f"Line {csv_line}: metadata differs between lanes for sample '{sample}'. "
                    f"Previous={previous_meta}, current={current_meta}"
                )
            else:
                sample_metadata.setdefault(sample, current_meta)

            previous_sex = patient_sex.get(patient)
            if previous_sex is not None and sex != "NA" and previous_sex != "NA" and previous_sex != sex:
                errors.append(
                    f"Line {csv_line}: inconsistent sex values for patient '{patient}': "
                    f"'{previous_sex}' and '{sex}'."
                )
            if previous_sex is None or previous_sex == "NA":
                patient_sex[patient] = sex

            for label, path in (("fastq_1", fq1), ("fastq_2", fq2)):
                previous = seen_fastqs.get(str(path))
                if previous is not None:
                    errors.append(
                        f"Line {csv_line}: FASTQ file is reused. {path} was already used as {previous}."
                    )
                else:
                    seen_fastqs[str(path)] = f"{patient}/{sample}/{lane}/{label}"

            rows.append(
                {
                    "patient": patient,
                    "sex": sex,
                    "status": status,
                    "sample": sample,
                    "lane": lane,
                    "fastq_1": str(fq1),
                    "fastq_2": str(fq2),
                }
            )

if not rows:
    errors.append("No usable data rows were found.")

if warnings:
    for warning in warnings:
        print(f"[WARN] {warning}", file=sys.stderr)

if errors:
    print("[ERROR] Samplesheet validation failed:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(2)

validated_csv.parent.mkdir(parents=True, exist_ok=True)
with validated_csv.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(
        handle,
        fieldnames=["patient", "sex", "status", "sample", "lane", "fastq_1", "fastq_2"],
    )
    writer.writeheader()
    writer.writerows(rows)

# The manifest has no header. Empty optional fields have already received defaults,
# so Bash tab parsing cannot shift columns.
with manifest_tsv.open("w", encoding="utf-8", newline="") as handle:
    for row in rows:
        values = [
            row["patient"],
            row["sample"],
            row["lane"],
            row["sex"],
            row["status"],
            row["fastq_1"],
            row["fastq_2"],
        ]
        if any("\t" in value or "\n" in value or "\r" in value for value in values):
            print("[ERROR] Tabs or newlines are not allowed in samplesheet values.", file=sys.stderr)
            sys.exit(2)
        handle.write("\t".join(values) + "\n")

with sample_metadata_tsv.open("w", encoding="utf-8", newline="") as handle:
    handle.write("patient\tsex\tstatus\tsample\n")
    for sample, (patient, sex, status) in sample_metadata.items():
        handle.write(f"{patient}\t{sex}\t{status}\t{sample}\n")

print(f"[OK] Validated {len(rows)} lane row(s) across {len(sample_metadata)} sample(s).")
PY

log "Validated samplesheet: $VALIDATED_CSV"

if [[ "$CHECK_GZIP" == true ]]; then
    CURRENT_STEP="checking gzip integrity"
    log "Running full gzip integrity checks. This reads every FASTQ completely."
    while IFS=$'\t' read -r patient sample lane sex status fq1 fq2; do
        gzip -t -- "$fq1" || die "gzip integrity check failed: $fq1"
        gzip -t -- "$fq2" || die "gzip integrity check failed: $fq2"
        log "[OK] gzip: $sample / $lane"
    done < "$MANIFEST_TSV"
fi

# ------------------------------------------------------------
# Reference validation and indexing
# ------------------------------------------------------------
CURRENT_STEP="preparing reference indexes"

# A minimal FASTA structure check.
first_nonempty=$(grep -m 1 -v '^[[:space:]]*$' "$REFERENCE" || true)
[[ "$first_nonempty" == '>'* ]] || die "Reference does not look like FASTA; first non-empty line must start with '>': $REFERENCE"

BWA_INDEX_FILES=(
    "${REFERENCE}.amb"
    "${REFERENCE}.ann"
    "${REFERENCE}.bwt"
    "${REFERENCE}.pac"
    "${REFERENCE}.sa"
)

bwa_index_complete=true
for index_file in "${BWA_INDEX_FILES[@]}"; do
    if [[ ! -s "$index_file" || "$index_file" -ot "$REFERENCE" ]]; then
        bwa_index_complete=false
        break
    fi
done

if [[ "$bwa_index_complete" == false ]]; then
    [[ -w "$(dirname "$REFERENCE")" ]] || die "Reference directory is not writable, so BWA indexes cannot be created: $(dirname "$REFERENCE")"
    log "BWA index is missing, incomplete, or older than the FASTA. Building index..."
    bwa index "$REFERENCE" > "$REF_LOG_DIR/bwa_index.log" 2>&1

    for index_file in "${BWA_INDEX_FILES[@]}"; do
        [[ -s "$index_file" ]] || die "BWA index creation finished but file is missing/empty: $index_file"
    done
    log "[OK] BWA index created."
else
    log "[SKIP] Complete BWA index already exists."
fi

if [[ ! -s "${REFERENCE}.fai" || "${REFERENCE}.fai" -ot "$REFERENCE" ]]; then
    [[ -w "$(dirname "$REFERENCE")" ]] || die "Reference directory is not writable, so the FASTA index cannot be created: $(dirname "$REFERENCE")"
    log "FASTA index (.fai) is missing or older than the FASTA. Building index..."
    samtools faidx "$REFERENCE" > "$REF_LOG_DIR/samtools_faidx.log" 2>&1
    [[ -s "${REFERENCE}.fai" ]] || die "samtools faidx did not create a valid .fai file."
    log "[OK] FASTA index created."
else
    log "[SKIP] FASTA index already exists."
fi

# Record reference sequence dictionary summary for provenance.
cut -f1,2 "${REFERENCE}.fai" > "$RUN_INFO_DIR/reference_contigs.tsv"

# ------------------------------------------------------------
# Lane-level QC and alignment
# ------------------------------------------------------------
declare -A SAMPLE_PATIENT=()
declare -A SAMPLE_SEX=()
declare -A SAMPLE_STATUS=()
declare -A SAMPLE_BAMS=()
declare -A SAMPLE_LANES=()
declare -a SAMPLE_ORDER=()

lane_count=0
sample_count=0

while IFS=$'\t' read -r patient sample lane sex status fq1 fq2; do
    ((lane_count += 1))

    if [[ -z "${SAMPLE_PATIENT[$sample]+x}" ]]; then
        SAMPLE_ORDER+=("$sample")
        SAMPLE_PATIENT["$sample"]=$patient
        SAMPLE_SEX["$sample"]=$sex
        SAMPLE_STATUS["$sample"]=$status
        SAMPLE_BAMS["$sample"]=""
        SAMPLE_LANES["$sample"]=""
        ((sample_count += 1))
    fi

    unit="${sample}.${lane}"
    lane_bam="$ALIGN_LANE_DIR/${unit}.sorted.bam"
    lane_bai="${lane_bam}.bai"
    lane_flagstat="$ALIGN_LANE_DIR/${unit}.flagstat.txt"
    lane_idxstats="$ALIGN_LANE_DIR/${unit}.idxstats.txt"
    lane_stats="$ALIGN_LANE_DIR/${unit}.stats.txt"
    lane_done="$ALIGN_LANE_DIR/${unit}.done"

    SAMPLE_BAMS["$sample"]+="$lane_bam"$'\n'
    SAMPLE_LANES["$sample"]+="$lane"$'\n'

    log "------------------------------------------------------------"
    log "Lane $lane_count: patient=$patient sample=$sample lane=$lane status=$status"
    log "R1: $fq1"
    log "R2: $fq2"

    if [[ "$RUN_FASTQC" == true ]]; then
        CURRENT_STEP="FastQC: $sample/$lane"
        fq1_base=$(basename "$fq1")
        fq2_base=$(basename "$fq2")
        fq1_stem=${fq1_base%.gz}
        fq1_stem=${fq1_stem%.fastq}
        fq1_stem=${fq1_stem%.fq}
        fq2_stem=${fq2_base%.gz}
        fq2_stem=${fq2_stem%.fastq}
        fq2_stem=${fq2_stem%.fq}

        fastqc_unit_dir="$QC_FASTQC_DIR/$unit"
        mkdir -p "$fastqc_unit_dir"

        fq1_html="$fastqc_unit_dir/${fq1_stem}_fastqc.html"
        fq1_zip="$fastqc_unit_dir/${fq1_stem}_fastqc.zip"
        fq2_html="$fastqc_unit_dir/${fq2_stem}_fastqc.html"
        fq2_zip="$fastqc_unit_dir/${fq2_stem}_fastqc.zip"

        if [[ "$FORCE" == false && -s "$fq1_html" && -s "$fq1_zip" && -s "$fq2_html" && -s "$fq2_zip" ]]; then
            log "[SKIP] FastQC outputs already exist for $sample/$lane."
        else
            rm -f -- "$fq1_html" "$fq1_zip" "$fq2_html" "$fq2_zip"
            fastqc_threads=$(( THREADS < 2 ? THREADS : 2 ))
            fastqc \
                --threads "$fastqc_threads" \
                --outdir "$fastqc_unit_dir" \
                "$fq1" "$fq2" \
                > "$FASTQC_LOG_DIR/${unit}.fastqc.log" 2>&1

            [[ -s "$fq1_html" && -s "$fq1_zip" && -s "$fq2_html" && -s "$fq2_zip" ]] \
                || die "FastQC did not create all expected outputs for $sample/$lane."
            log "[OK] FastQC finished for $sample/$lane."
        fi
    fi

    CURRENT_STEP="alignment: $sample/$lane"

    lane_valid=false
    if [[ "$FORCE" == false && -s "$lane_bam" && -s "$lane_bai" && -f "$lane_done" ]]; then
        if samtools quickcheck -q "$lane_bam"; then
            lane_valid=true
        else
            warn "Existing lane BAM is invalid and will be recreated: $lane_bam"
        fi
    fi

    if [[ "$lane_valid" == true ]]; then
        log "[SKIP] Valid lane BAM already exists: $lane_bam"
    else
        rm -f -- \
            "$lane_bam" "$lane_bai" "$lane_done" \
            "$lane_flagstat" "$lane_idxstats" "$lane_stats"

        tmp_bam="${lane_bam}.tmp.$$"
        TMP_FILES+=("$tmp_bam")

        rg_id="${sample}.${lane}"
        read_group="@RG\\tID:${rg_id}\\tSM:${sample}\\tLB:${sample}\\tPL:${PLATFORM}\\tPU:${lane}"

        log "Running BWA-MEM and coordinate sorting..."
        bwa mem \
            -K 100000000 \
            -Y \
            -t "$THREADS" \
            -R "$read_group" \
            "$REFERENCE" \
            "$fq1" \
            "$fq2" \
            2> "$ALIGN_LOG_DIR/${unit}.bwa.log" \
        | samtools sort \
            -@ "$THREADS" \
            -o "$tmp_bam" \
            - \
            2> "$ALIGN_LOG_DIR/${unit}.samtools_sort.log"

        samtools quickcheck -v "$tmp_bam" \
            > "$ALIGN_LOG_DIR/${unit}.quickcheck.log" 2>&1 \
            || die "samtools quickcheck failed for temporary BAM: $tmp_bam"

        mv -f -- "$tmp_bam" "$lane_bam"
        samtools index -@ "$THREADS" "$lane_bam" "$lane_bai"

        samtools flagstat -@ "$THREADS" "$lane_bam" > "$lane_flagstat"
        samtools idxstats "$lane_bam" > "$lane_idxstats"
        samtools stats -@ "$THREADS" "$lane_bam" > "$lane_stats"

        [[ -s "$lane_bam" && -s "$lane_bai" && -s "$lane_flagstat" ]] \
            || die "One or more lane-level outputs are missing for $sample/$lane."

        touch "$lane_done"
        log "[OK] Alignment finished for $sample/$lane."
    fi
done < "$MANIFEST_TSV"

[[ "$lane_count" -gt 0 ]] || die "No samplesheet rows were processed."

# ------------------------------------------------------------
# Sample-level merge
# ------------------------------------------------------------
CURRENT_STEP="sample-level lane merging"

for sample in "${SAMPLE_ORDER[@]}"; do
    patient=${SAMPLE_PATIENT[$sample]}
    sex=${SAMPLE_SEX[$sample]}
    status=${SAMPLE_STATUS[$sample]}

    mapfile -t lane_bams < <(printf '%s' "${SAMPLE_BAMS[$sample]}")
    mapfile -t lanes < <(printf '%s' "${SAMPLE_LANES[$sample]}")

    [[ "${#lane_bams[@]}" -gt 0 ]] || die "Internal error: no lane BAMs registered for sample $sample."

    sample_bam="$ALIGN_SAMPLE_DIR/${sample}.sorted.bam"
    sample_bai="${sample_bam}.bai"
    sample_flagstat="$ALIGN_SAMPLE_DIR/${sample}.flagstat.txt"
    sample_idxstats="$ALIGN_SAMPLE_DIR/${sample}.idxstats.txt"
    sample_stats="$ALIGN_SAMPLE_DIR/${sample}.stats.txt"
    sample_done="$ALIGN_SAMPLE_DIR/${sample}.done"

    log "------------------------------------------------------------"
    log "Sample merge: patient=$patient sample=$sample lanes=${#lane_bams[@]} status=$status sex=$sex"

    sample_valid=false
    if [[ "$FORCE" == false && -s "$sample_bam" && -s "$sample_bai" && -f "$sample_done" ]]; then
        if samtools quickcheck -q "$sample_bam"; then
            sample_valid=true
        else
            warn "Existing sample BAM is invalid and will be recreated: $sample_bam"
        fi
    fi

    if [[ "$sample_valid" == true ]]; then
        log "[SKIP] Valid sample BAM already exists: $sample_bam"
        continue
    fi

    rm -f -- \
        "$sample_bam" "$sample_bai" "$sample_done" \
        "$sample_flagstat" "$sample_idxstats" "$sample_stats"

    tmp_sample_bam="${sample_bam}.tmp.$$"
    TMP_FILES+=("$tmp_sample_bam")

    for bam in "${lane_bams[@]}"; do
        [[ -s "$bam" ]] || die "Lane BAM required for merge is missing: $bam"
        samtools quickcheck -q "$bam" || die "Lane BAM required for merge is invalid: $bam"
    done

    if [[ "${#lane_bams[@]}" -eq 1 ]]; then
        # The lane BAM already has sample-level read-group metadata. A hard link avoids
        # duplicating a large BAM; copying is used only if hard-linking is unavailable.
        ln "${lane_bams[0]}" "$tmp_sample_bam" 2>/dev/null \
            || cp --reflink=auto --sparse=always "${lane_bams[0]}" "$tmp_sample_bam" 2>/dev/null \
            || cp "${lane_bams[0]}" "$tmp_sample_bam"
    else
        samtools merge \
            -@ "$THREADS" \
            -f \
            -o "$tmp_sample_bam" \
            "${lane_bams[@]}" \
            > "$MERGE_LOG_DIR/${sample}.samtools_merge.log" 2>&1
    fi

    samtools quickcheck -v "$tmp_sample_bam" \
        > "$MERGE_LOG_DIR/${sample}.quickcheck.log" 2>&1 \
        || die "samtools quickcheck failed for merged sample BAM: $tmp_sample_bam"

    mv -f -- "$tmp_sample_bam" "$sample_bam"
    samtools index -@ "$THREADS" "$sample_bam" "$sample_bai"

    samtools flagstat -@ "$THREADS" "$sample_bam" > "$sample_flagstat"
    samtools idxstats "$sample_bam" > "$sample_idxstats"
    samtools stats -@ "$THREADS" "$sample_bam" > "$sample_stats"

    [[ -s "$sample_bam" && -s "$sample_bai" && -s "$sample_flagstat" ]] \
        || die "One or more sample-level outputs are missing for sample $sample."

    touch "$sample_done"
    log "[OK] Sample-level BAM ready: $sample_bam"

    if [[ "$KEEP_LANE_BAM" == false && "${#lane_bams[@]}" -gt 1 ]]; then
        for bam in "${lane_bams[@]}"; do
            rm -f -- \
                "$bam" "${bam}.bai" \
                "${bam%.sorted.bam}.flagstat.txt" \
                "${bam%.sorted.bam}.idxstats.txt" \
                "${bam%.sorted.bam}.stats.txt" \
                "${bam%.sorted.bam}.done"
        done
        log "Removed lane BAMs after successful merge for sample $sample."
    fi
done

# ------------------------------------------------------------
# Write downstream-ready sample BAM samplesheet
# ------------------------------------------------------------
CURRENT_STEP="writing output samplesheet"
MAPPED_CSV="$RUN_INFO_DIR/mapped.csv"

python3 - "$SAMPLE_METADATA_TSV" "$ALIGN_SAMPLE_DIR" "$MAPPED_CSV" <<'PY'
import csv
import sys
from pathlib import Path

metadata_tsv = Path(sys.argv[1])
align_dir = Path(sys.argv[2]).resolve()
out_csv = Path(sys.argv[3])

rows = []
with metadata_tsv.open("r", encoding="utf-8", newline="") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        sample = row["sample"]
        bam = align_dir / f"{sample}.sorted.bam"
        bai = Path(str(bam) + ".bai")
        if not bam.is_file() or not bai.is_file():
            raise SystemExit(f"Missing mapped BAM or BAI for sample: {sample}")
        rows.append(
            {
                "patient": row["patient"],
                "sex": row["sex"],
                "status": row["status"],
                "sample": sample,
                "bam": str(bam),
                "bai": str(bai),
            }
        )

with out_csv.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=["patient", "sex", "status", "sample", "bam", "bai"])
    writer.writeheader()
    writer.writerows(rows)
PY

# ------------------------------------------------------------
# MultiQC
# ------------------------------------------------------------
if [[ "$RUN_MULTIQC" == true ]]; then
    CURRENT_STEP="MultiQC"
    log "Running MultiQC..."
    multiqc \
        --force \
        --outdir "$QC_MULTIQC_DIR" \
        "$QC_FASTQC_DIR" \
        "$ALIGN_LANE_DIR" \
        "$ALIGN_SAMPLE_DIR" \
        > "$LOG_DIR/multiqc.log" 2>&1

    [[ -s "$QC_MULTIQC_DIR/multiqc_report.html" ]] \
        || die "MultiQC did not create multiqc_report.html."
    log "[OK] MultiQC finished."
fi

CURRENT_STEP="finalizing"
{
    echo "run_finished=$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "lane_rows=$lane_count"
    echo "samples=$sample_count"
    echo "validated_input=$VALIDATED_CSV"
    echo "mapped_samplesheet=$MAPPED_CSV"
    echo "sample_bam_dir=$ALIGN_SAMPLE_DIR"
    echo "multiqc_report=$QC_MULTIQC_DIR/multiqc_report.html"
} > "$RUN_INFO_DIR/run_summary.txt"

log "============================================================"
log "[DONE] Pipeline finished successfully."
log "Validated input : $VALIDATED_CSV"
log "Mapped CSV      : $MAPPED_CSV"
log "Sample BAMs     : $ALIGN_SAMPLE_DIR"
log "FastQC          : $QC_FASTQC_DIR"
if [[ "$RUN_MULTIQC" == true ]]; then
    log "MultiQC         : $QC_MULTIQC_DIR/multiqc_report.html"
fi
log "Pipeline log    : $PIPELINE_LOG"
log "============================================================"