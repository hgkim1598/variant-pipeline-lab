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

# ==============================================================================
# KMG - Trimming
# ==============================================================================
#!/usr/bin/env bash
# =============================================================================
#  02_trimming.sh — fastp Adapter Trimming [추가 단계]
#
#  [웹 연동 호출 방식]
#  환경변수로 입력 파일을 받거나, 인수로 직접 지정:
#    # 방식 1: 환경변수
#    export INPUT_R1="/path/to/sample_R1.fastq.gz"
#    export INPUT_R2="/path/to/sample_R2.fastq.gz"
#    bash 02_trimming.sh
#
#    # 방식 2: 인수 직접 지정
#    bash 02_trimming.sh /path/to/sample_R1.fastq.gz /path/to/sample_R2.fastq.gz
#
#    # 방식 3: 업로드 디렉토리 자동 감지 (파일 1개만 있을 때)
#    export UPLOAD_DIR="/upload/sessionXXX"
#    bash 02_trimming.sh
#
#  [지원 파일명 패턴]
#    sample_R1.fastq.gz / sample_R2.fastq.gz
#    sample_R1_001.fastq.gz / sample_R2_001.fastq.gz
#    sample_1.fastq.gz / sample_2.fastq.gz
#    sample_1.fq.gz / sample_2.fq.gz
# =============================================================================
set -euo pipefail

THREADS="${THREADS:-8}"
BASE_DIR="${BASE_DIR:-$HOME/giab_wes}"

# ── 입력 파일 결정 함수 ───────────────────────────────────────────────────────
detect_inputs() {
    # 우선순위 1: 인수로 직접 전달
    if [[ $# -ge 2 ]]; then
        echo "$1 $2"
        return
    fi

    # 우선순위 2: 환경변수 INPUT_R1 / INPUT_R2
    if [[ -n "${INPUT_R1:-}" && -n "${INPUT_R2:-}" ]]; then
        echo "${INPUT_R1} ${INPUT_R2}"
        return
    fi

    # 우선순위 3: UPLOAD_DIR 에서 자동 감지
    local SEARCH_DIR="${UPLOAD_DIR:-${BASE_DIR}/fastq}"
    local R1="" R2=""

    # _R1_ 또는 _1. 패턴의 FASTQ 파일 검색
    while IFS= read -r f; do
        if [[ -z "${R1}" ]]; then
            R1="$f"
            # R2 자동 매칭
            R2="${f/_R1_/_R2_}"
            R2="${R2/_R1./_R2.}"
            R2="${R2/_1.fastq/_2.fastq}"
            R2="${R2/_1.fq/_2.fq}"
        fi
    done < <(find "${SEARCH_DIR}" -maxdepth 2 \
        \( -name "*_R1_*.fastq.gz" -o -name "*_R1_*.fq.gz" \
           -o -name "*_R1.fastq.gz"  -o -name "*_R1.fq.gz" \
           -o -name "*_1.fastq.gz"   -o -name "*_1.fq.gz" \) \
        2>/dev/null | sort)

    if [[ -z "${R1}" || ! -f "${R2}" ]]; then
        echo "ERROR: R1/R2 FASTQ 파일을 찾을 수 없습니다." >&2
        echo "  검색 경로: ${SEARCH_DIR}" >&2
        echo "  INPUT_R1, INPUT_R2 환경변수를 직접 지정하거나 인수로 파일 경로를 전달하세요." >&2
        exit 1
    fi
    echo "${R1} ${R2}"
}

# ── Sample ID 추출 함수 ───────────────────────────────────────────────────────
extract_sample_id() {
    local R1_PATH="$1"
    local FNAME
    FNAME=$(basename "${R1_PATH}")

    # 패턴 제거: _R1_001, _R1, _1 + 확장자
    local SAMPLE_ID
    SAMPLE_ID="${FNAME}"
    SAMPLE_ID="${SAMPLE_ID/_R1_001.fastq.gz/}"
    SAMPLE_ID="${SAMPLE_ID/_R1_001.fq.gz/}"
    SAMPLE_ID="${SAMPLE_ID/_R1.fastq.gz/}"
    SAMPLE_ID="${SAMPLE_ID/_R1.fq.gz/}"
    SAMPLE_ID="${SAMPLE_ID/_1.fastq.gz/}"
    SAMPLE_ID="${SAMPLE_ID/_1.fq.gz/}"

    # 공백·특수문자 제거
    SAMPLE_ID="${SAMPLE_ID//[^a-zA-Z0-9_\-]/}"
    echo "${SAMPLE_ID}"
}

# ── 메인 ──────────────────────────────────────────────────────────────────────
main() {
    # 입력 파일 결정
    local INPUTS
    INPUTS=$(detect_inputs "$@")
    read -r INPUT_R1_FINAL INPUT_R2_FINAL <<< "${INPUTS}"

    # Sample ID 추출
    SAMPLE_ID=$(extract_sample_id "${INPUT_R1_FINAL}")
    echo "=== [02] fastp Trimming ==="
    echo "  Sample ID : ${SAMPLE_ID}"
    echo "  R1 입력   : ${INPUT_R1_FINAL}"
    echo "  R2 입력   : ${INPUT_R2_FINAL}"

    # 출력 경로 설정 (Sample ID 기반)
    CLEAN_DIR="${BASE_DIR}/samples/${SAMPLE_ID}/fastq_clean"
    QC_DIR="${BASE_DIR}/samples/${SAMPLE_ID}/qc/fastp"
    mkdir -p "${CLEAN_DIR}" "${QC_DIR}"

    local R1_CLEAN="${CLEAN_DIR}/${SAMPLE_ID}_R1.clean.fastq.gz"
    local R2_CLEAN="${CLEAN_DIR}/${SAMPLE_ID}_R2.clean.fastq.gz"

    # fastp 설치 확인
    if ! command -v fastp &>/dev/null; then
        echo "  fastp 미설치 → conda install 실행..."
        conda install -c bioconda fastp -y
    fi

    # fastp 실행
    fastp \
        -i  "${INPUT_R1_FINAL}" \
        -I  "${INPUT_R2_FINAL}" \
        -o  "${R1_CLEAN}" \
        -O  "${R2_CLEAN}" \
        --detect_adapter_for_pe \
        --qualified_quality_phred 20 \
        --unqualified_percent_limit 40 \
        --length_required 50 \
        --thread "${THREADS}" \
        --json "${QC_DIR}/fastp.json" \
        --html "${QC_DIR}/fastp.html"

    # 결과 요약 출력 (웹 백엔드가 파싱할 수 있도록 JSON 경로 명시)
    echo ""
    echo "=== [02] 완료 ==="
    echo "  SAMPLE_ID=${SAMPLE_ID}"
    echo "  R1_CLEAN=${R1_CLEAN}"
    echo "  R2_CLEAN=${R2_CLEAN}"
    echo "  QC_REPORT=${QC_DIR}/fastp.html"
    echo "  QC_JSON=${QC_DIR}/fastp.json"
    echo "  NEXT_STEP=03_alignment.sh"
}

main "$@"

# ==============================================================================
# KMG - Trimming
# ==============================================================================

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
# Validate and normalize CSV with Python's csv module.
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


###############################################################################
# 7. Execute — no manual checkpoints
###############################################################################

log "PIPELINE START — no manual checkpoint will be requested."

if (( DO_FASTQC == 1 )); then
  mkdir -p "$QC_DIR/fastqc_raw"
  run_cmd "00_fastqc_raw" fastqc --threads "$FASTQC_THREADS" --outdir "$QC_DIR/fastqc_raw" "$FQ1" "$FQ2"
fi
printf 'trim_mode\tnone\nreason\tNo automatic trimming; project policy requires an explicit QC-based decision.\n' > "$QC_DIR/${PREFIX}.trim_decision.tsv"

CURRENT_STAGE="01_alignment"
ALIGN_START="$(date +%s)"
printf '%s\t%s\tSTARTED\t0\n' "$(date -Is)" "$CURRENT_STAGE" >> "$STATUS_TSV"
log "START 01_alignment: BWA-MEM -> samtools coordinate sort"
{
  echo "# $(date -Is) — 01_alignment"
  printf '%q ' bwa mem -K 100000000 -t "$THREADS" -Y -R "$RG_STRING" "$REF" "$FQ1" "$FQ2"
  printf ' | '
  printf '%q ' samtools sort -@ "$SORT_THREADS" -m "$SORT_MEM" -T "$TMP_DIR/sort_tmp" -O bam -o "$SORTED_PART" -
  printf '\n\n'
} >> "$COMMANDS_SH"
set +e
bwa mem -K 100000000 -t "$THREADS" -Y -R "$RG_STRING" "$REF" "$FQ1" "$FQ2" \
  2> "$LOG_DIR/01_bwa_mem.stderr.log" \
  | samtools sort -@ "$SORT_THREADS" -m "$SORT_MEM" -T "$TMP_DIR/sort_tmp" -O bam -o "$SORTED_PART" - \
      2> "$LOG_DIR/01_samtools_sort.stderr.log"
PIPE_RC=("${PIPESTATUS[@]}")
set -e
if (( PIPE_RC[0] != 0 || PIPE_RC[1] != 0 )); then
  printf '%s\t%s\tFAILED\t%s\n' "$(date -Is)" "$CURRENT_STAGE" "${PIPE_RC[0]}|${PIPE_RC[1]}" >> "$STATUS_TSV"
  printf 'FAILED\n' > "$LOG_DIR/RUN_FAILED"
  echo "ERROR: alignment pipeline failed; bwa=${PIPE_RC[0]}, samtools_sort=${PIPE_RC[1]}" >&2
  exit 1
fi
mv "$SORTED_PART" "$SORTED_BAM"
samtools quickcheck -v "$SORTED_BAM"
samtools view -H "$SORTED_BAM" | grep '^@HD.*SO:coordinate' >/dev/null
ALIGN_END="$(date +%s)"
printf '%s\t%s\tCOMPLETED\t0\n' "$(date -Is)" "$CURRENT_STAGE" >> "$STATUS_TSV"
printf '%s\t%s\t%s\n' "$CURRENT_STAGE" "$((ALIGN_END-ALIGN_START))" "$(date -Is)" >> "$TRACE_TSV"
log "DONE  01_alignment ($((ALIGN_END-ALIGN_START)) sec)"

run_cmd "02_markduplicates" \
  gatk --java-options "-Xmx${JAVA_MEM_GB}g -Djava.io.tmpdir=$TMP_DIR" MarkDuplicates \
    -I "$SORTED_BAM" -O "$MARKDUP_PART" -M "$MARKDUP_METRICS" \
    --REMOVE_DUPLICATES false --CREATE_INDEX false \
    "${READ_NAME_REGEX_ARGS[@]}" --TMP_DIR "$TMP_DIR"
mv "$MARKDUP_PART" "$MARKDUP_BAM"
samtools quickcheck -v "$MARKDUP_BAM"

# hs37d5 contains ambiguous reference symbols at some loci. In this dataset,
# BWA and Picard can disagree on a small number of NM/MD tags even though the
# alignments themselves are valid. Recalculate only NM/MD against the exact
# reference before strict Picard validation; read sequence, CIGAR, coordinate
# and duplicate flags are preserved.
CURRENT_STAGE="02b_recalculate_nm_md"
NM_START="$(date +%s)"
printf '%s\t%s\tSTARTED\t0\n' "$(date -Is)" "$CURRENT_STAGE" >> "$STATUS_TSV"
log "START 02b_recalculate_nm_md: samtools calmd"
{
  echo "# $(date -Is) — 02b_recalculate_nm_md"
  printf '%q ' samtools calmd -@ "$THREADS" -b "$MARKDUP_BAM" "$REF"
  printf ' > %q 2> %q\n\n' "$MARKDUP_NM_PART" "$LOG_DIR/02b_calmd.stderr.log"
} >> "$COMMANDS_SH"

if [[ -x /usr/bin/time ]]; then
  if /usr/bin/time -v -o "$LOG_DIR/resource_02b_recalculate_nm_md.txt" \
      samtools calmd -@ "$THREADS" -b "$MARKDUP_BAM" "$REF" \
      > "$MARKDUP_NM_PART" 2> "$LOG_DIR/02b_calmd.stderr.log"; then NM_RC=0; else NM_RC=$?; fi
else
  if samtools calmd -@ "$THREADS" -b "$MARKDUP_BAM" "$REF" \
      > "$MARKDUP_NM_PART" 2> "$LOG_DIR/02b_calmd.stderr.log"; then NM_RC=0; else NM_RC=$?; fi
fi

if (( NM_RC != 0 )); then
  printf '%s\t%s\tFAILED\t%s\n' "$(date -Is)" "$CURRENT_STAGE" "$NM_RC" >> "$STATUS_TSV"
  printf 'FAILED\n' > "$LOG_DIR/RUN_FAILED"
  echo "ERROR: samtools calmd failed; see $LOG_DIR/02b_calmd.stderr.log" >&2
  trap - ERR
  exit "$NM_RC"
fi
samtools quickcheck -v "$MARKDUP_NM_PART"
mv "$MARKDUP_NM_PART" "$MARKDUP_BAM"
NM_END="$(date +%s)"
printf '%s\t%s\tCOMPLETED\t0\n' "$(date -Is)" "$CURRENT_STAGE" >> "$STATUS_TSV"
printf '%s\t%s\t%s\n' "$CURRENT_STAGE" "$((NM_END-NM_START))" "$(date -Is)" >> "$TRACE_TSV"
log "DONE  02b_recalculate_nm_md ($((NM_END-NM_START)) sec)"

run_cmd "02c_markdup_index" samtools index -@ "$THREADS" "$MARKDUP_BAM"
samtools quickcheck -v "$MARKDUP_BAM"

CURRENT_STAGE="03_markdup_qc"
samtools flagstat -@ "$THREADS" "$MARKDUP_BAM" > "$QC_DIR/${PREFIX}.markdup.flagstat.txt"
samtools stats -@ "$THREADS" "$MARKDUP_BAM" > "$QC_DIR/${PREFIX}.markdup.stats.txt"
run_cmd "03_validate_markdup_bam" gatk --java-options "-Xmx4g" ValidateSamFile \
  -I "$MARKDUP_BAM" -R "$REF" -MODE SUMMARY -O "$QC_DIR/${PREFIX}.markdup.validation.txt"

BQSR_INTERVAL_ARGS=()
if (( BQSR_TARGET_ONLY == 1 )); then BQSR_INTERVAL_ARGS=(-L "$TARGET_BED" -ip "$INTERVAL_PADDING"); fi
run_cmd "04_base_recalibrator" \
  gatk --java-options "-Xmx${JAVA_MEM_GB}g -Djava.io.tmpdir=$TMP_DIR" BaseRecalibrator \
    -R "$REF" -I "$MARKDUP_BAM" \
    --known-sites "$DBSNP" --known-sites "$MILLS" --known-sites "$KG_INDELS" \
    "${BQSR_INTERVAL_ARGS[@]}" -O "$RECAL_PART" --tmp-dir "$TMP_DIR"
mv "$RECAL_PART" "$RECAL_TABLE"
grep -q 'RecalTable0' "$RECAL_TABLE"

# No -L here: ApplyBQSR must preserve the complete BAM rather than emit only
# interval-overlapping reads.
run_cmd "05_apply_bqsr" \
  gatk --java-options "-Xmx${JAVA_MEM_GB}g -Djava.io.tmpdir=$TMP_DIR" ApplyBQSR \
    -R "$REF" -I "$MARKDUP_BAM" --bqsr-recal-file "$RECAL_TABLE" \
    -O "$FINAL_PART" --create-output-bam-index false --tmp-dir "$TMP_DIR"
mv "$FINAL_PART" "$FINAL_BAM"
run_cmd "05b_analysis_bam_index" samtools index -@ "$THREADS" "$FINAL_BAM"
samtools quickcheck -v "$FINAL_BAM"

CURRENT_STAGE="06_analysis_bam_qc"
samtools flagstat -@ "$THREADS" "$FINAL_BAM" > "$QC_DIR/${PREFIX}.analysis_ready.flagstat.txt"
samtools stats -@ "$THREADS" "$FINAL_BAM" > "$QC_DIR/${PREFIX}.analysis_ready.stats.txt"
run_cmd "06_validate_analysis_bam" gatk --java-options "-Xmx4g" ValidateSamFile \
  -I "$FINAL_BAM" -R "$REF" -MODE SUMMARY -O "$QC_DIR/${PREFIX}.analysis_ready.validation.txt"

if (( DO_BQSR_DIAGNOSTICS == 1 )); then
  run_optional_cmd "06b_recal_after" \
    gatk --java-options "-Xmx${JAVA_MEM_GB}g -Djava.io.tmpdir=$TMP_DIR" BaseRecalibrator \
      -R "$REF" -I "$FINAL_BAM" \
      --known-sites "$DBSNP" --known-sites "$MILLS" --known-sites "$KG_INDELS" \
      "${BQSR_INTERVAL_ARGS[@]}" -O "$RECAL_AFTER" --tmp-dir "$TMP_DIR"
  if [[ -s "$RECAL_AFTER" ]]; then
    run_optional_cmd "06c_analyze_covariates" gatk --java-options "-Xmx${JAVA_MEM_GB}g" AnalyzeCovariates \
      -before "$RECAL_TABLE" -after "$RECAL_AFTER" \
      -csv "$QC_DIR/${PREFIX}.bqsr_covariates.csv" -plots "$QC_DIR/${PREFIX}.bqsr_covariates.pdf"
  fi
fi

run_cmd "07_target_coverage" mosdepth --threads "$THREADS" --no-per-base --mapq "$MOSDEPTH_MAPQ" \
  --by "$MERGED_BED" --thresholds 1,10,20,30,50,100 \
  "$QC_DIR/${PREFIX}.mosdepth" "$FINAL_BAM"

run_cmd "08_haplotypecaller_gvcf" \
  gatk --java-options "-Xmx${JAVA_MEM_GB}g -Djava.io.tmpdir=$TMP_DIR" HaplotypeCaller \
    -R "$REF" -I "$FINAL_BAM" -ERC GVCF \
    -L "$TARGET_BED" -ip "$INTERVAL_PADDING" \
    --native-pair-hmm-threads "$PAIRHMM_THREADS" \
    -O "$GVCF_PART" --tmp-dir "$TMP_DIR"
mv "$GVCF_PART" "$GVCF"
if [[ -s "${GVCF_PART}.tbi" ]]; then mv "${GVCF_PART}.tbi" "${GVCF}.tbi"; fi
[[ -s "${GVCF}.tbi" ]] || run_cmd "08b_gvcf_index" tabix -p vcf "$GVCF"

run_cmd "09_genotype_gvcfs" \
  gatk --java-options "-Xmx${JAVA_MEM_GB}g -Djava.io.tmpdir=$TMP_DIR" GenotypeGVCFs \
    -R "$REF" -V "$GVCF" --dbsnp "$DBSNP" \
    -L "$TARGET_BED" -ip "$INTERVAL_PADDING" \
    -O "$RAW_PART" --tmp-dir "$TMP_DIR"
mv "$RAW_PART" "$RAW_VCF"
if [[ -s "${RAW_PART}.tbi" ]]; then mv "${RAW_PART}.tbi" "${RAW_VCF}.tbi"; fi
[[ -s "${RAW_VCF}.tbi" ]] || run_cmd "09b_raw_vcf_index" tabix -p vcf "$RAW_VCF"

###############################################################################
# 8. Final consolidated validation and web-facing outputs
###############################################################################

set +e
CURRENT_STAGE="10_final_validation"
log "START 10_final_validation — all outputs will be checked together."
printf 'check\tstatus\tdetail\n' > "$FINAL_VALIDATION"
V_PASS=(); V_WARN=(); V_FAIL=()
vpass() { V_PASS+=("$1: $2"); printf '%s\tPASS\t%s\n' "$1" "$2" >> "$FINAL_VALIDATION"; }
vwarn() { V_WARN+=("$1: $2"); printf '%s\tWARN\t%s\n' "$1" "$2" >> "$FINAL_VALIDATION"; }
vfail() { V_FAIL+=("$1: $2"); printf '%s\tFAIL\t%s\n' "$1" "$2" >> "$FINAL_VALIDATION"; }

for f in "$SORTED_BAM" "$MARKDUP_BAM" "$MARKDUP_METRICS" "$RECAL_TABLE" "$FINAL_BAM" "$GVCF" "$RAW_VCF"; do
  [[ -s "$f" ]] || vfail "required_artifact" "missing/empty: $f"
done
(( ${#V_FAIL[@]} == 0 )) && vpass "required_artifacts" "all core artifacts exist and are non-empty"

samtools quickcheck -v "$SORTED_BAM" "$MARKDUP_BAM" "$FINAL_BAM" >/dev/null 2>&1 \
  && vpass "bam_quickcheck" "sorted, markdup and analysis-ready BAM passed" \
  || vfail "bam_quickcheck" "one or more BAM files failed"

BAM_SORT_FAIL=0
for bam in "$SORTED_BAM" "$MARKDUP_BAM" "$FINAL_BAM"; do
  samtools view -H "$bam" 2>/dev/null | grep '^@HD.*SO:coordinate' >/dev/null \
    || { vfail "bam_sort_order" "SO:coordinate missing: $bam"; BAM_SORT_FAIL=1; }
done
(( BAM_SORT_FAIL == 0 )) && vpass "bam_sort_order" "all BAM headers report coordinate sort"

BAM_INDEX_FAIL=0
for bam in "$MARKDUP_BAM" "$FINAL_BAM"; do
  samtools idxstats "$bam" >/dev/null 2>&1 \
    || { vfail "bam_index" "index missing/unreadable: $bam"; BAM_INDEX_FAIL=1; }
done
(( BAM_INDEX_FAIL == 0 )) && vpass "bam_indexes" "markdup and analysis-ready indexes are readable"

samtools view -H "$FINAL_BAM" 2>/dev/null | grep "SM:${RG_SM}" >/dev/null \
  && vpass "read_group_sample" "SM:${RG_SM} present" \
  || vfail "read_group_sample" "SM:${RG_SM} missing"

MARKDUP_TOTAL="$(awk 'NR==1 {print $1}' "$QC_DIR/${PREFIX}.markdup.flagstat.txt" 2>/dev/null)"
FINAL_TOTAL="$(awk 'NR==1 {print $1}' "$QC_DIR/${PREFIX}.analysis_ready.flagstat.txt" 2>/dev/null)"
if [[ -n "$MARKDUP_TOTAL" && "$MARKDUP_TOTAL" == "$FINAL_TOTAL" ]]; then
  vpass "applybqsr_record_preservation" "before=$MARKDUP_TOTAL after=$FINAL_TOTAL"
else
  vfail "applybqsr_record_preservation" "before=${MARKDUP_TOTAL:-NA} after=${FINAL_TOTAL:-NA}"
fi

VCF_PARSE_FAIL=0
VCF_INDEX_FAIL=0
for vcf in "$GVCF" "$RAW_VCF"; do
  bcftools view -h "$vcf" >/dev/null 2>&1 \
    || { vfail "vcf_parse" "cannot parse $vcf"; VCF_PARSE_FAIL=1; }
  tabix -l "$vcf" >/dev/null 2>&1 \
    || { vfail "vcf_index" "index missing/unreadable: $vcf"; VCF_INDEX_FAIL=1; }
done
(( VCF_PARSE_FAIL == 0 )) && vpass "vcf_parse" "gVCF and raw VCF parse"
(( VCF_INDEX_FAIL == 0 )) && vpass "vcf_indexes" "gVCF and raw VCF indexes are readable"

VCF_SAMPLE="$(bcftools query -l "$RAW_VCF" 2>/dev/null)"
[[ "$VCF_SAMPLE" == "$RG_SM" ]] && vpass "vcf_sample" "$VCF_SAMPLE" || vfail "vcf_sample" "expected=$RG_SM observed=${VCF_SAMPLE:-NA}"

RAW_RECORDS="$(bcftools view -H "$RAW_VCF" 2>/dev/null | wc -l)"
if is_uint "$RAW_RECORDS" && (( RAW_RECORDS > 0 )); then vpass "raw_vcf_records" "$RAW_RECORDS"; else vfail "raw_vcf_records" "record count is ${RAW_RECORDS:-NA}"; fi

bcftools norm -f "$REF" -c e -Ou -o /dev/null "$RAW_VCF" 2> "$LOG_DIR/10_raw_vcf_ref_check.log" \
  && vpass "raw_vcf_ref_match" "all REF alleles match hs37d5" \
  || vfail "raw_vcf_ref_match" "REF allele mismatch; see 10_raw_vcf_ref_check.log"

bcftools stats "$RAW_VCF" > "$QC_DIR/${PREFIX}.raw.bcftools.stats.txt" 2>/dev/null \
  || vfail "bcftools_stats" "could not create VCF statistics"
[[ -s "$QC_DIR/${PREFIX}.raw.bcftools.stats.txt" ]] && vpass "bcftools_stats" "raw VCF statistics created"

python3 - "$SAMPLE" "$RUN_ID" "$READ_PAIRS" \
  "$QC_DIR/${PREFIX}.analysis_ready.flagstat.txt" "$MARKDUP_METRICS" \
  "$QC_DIR/${PREFIX}.mosdepth.regions.bed.gz" "$QC_DIR/${PREFIX}.mosdepth.thresholds.bed.gz" \
  "$QC_DIR/${PREFIX}.raw.bcftools.stats.txt" "$METRICS_JSON" <<'PYMETRICS'
import gzip,json,re,sys
from pathlib import Path
sample,run_id,read_pairs,flagstat,mdmetrics,regions,thresholds,stats,out=sys.argv[1:]
m={"sample":sample,"run_id":run_id,"input_read_pairs":int(read_pairs)}
txt=Path(flagstat).read_text()
for k,p in {"total_alignment_records":r'^(\d+) \+ \d+ in total',"mapped_records":r'^(\d+) \+ \d+ mapped',"properly_paired_records":r'^(\d+) \+ \d+ properly paired',"duplicate_records":r'^(\d+) \+ \d+ duplicates'}.items():
    x=re.search(p,txt,re.M)
    if x: m[k]=int(x.group(1))
for k,p in {"mapped_pct":r'mapped \(([-0-9.]+)%',"properly_paired_pct":r'properly paired \(([-0-9.]+)%'}.items():
    x=re.search(p,txt)
    if x: m[k]=float(x.group(1))
lines=[x for x in Path(mdmetrics).read_text().splitlines() if x and not x.startswith('#')]
for i,line in enumerate(lines):
    if line.startswith('LIBRARY') and i+1<len(lines):
        row=dict(zip(line.split('\t'),lines[i+1].split('\t')))
        if row.get('PERCENT_DUPLICATION'): m['picard_percent_duplication']=float(row['PERCENT_DUPLICATION'])
        if row.get('ESTIMATED_LIBRARY_SIZE'):
            try:m['estimated_library_size']=int(row['ESTIMATED_LIBRARY_SIZE'])
            except ValueError:m['estimated_library_size']=row['ESTIMATED_LIBRARY_SIZE']
        break
rp=Path(regions)
if rp.exists():
    bases=0; depth_bases=0.0
    with gzip.open(rp,'rt') as fh:
        for line in fh:
            if not line.strip() or line.startswith('#'):continue
            f=line.rstrip().split('\t'); length=int(f[2])-int(f[1]); depth=float(f[-1]); bases+=length; depth_bases+=length*depth
    if bases:m['target_nonoverlap_bases']=bases;m['mean_target_depth']=round(depth_bases/bases,4)
tp=Path(thresholds)
if tp.exists():
    names=[];idx=[];sums=[];total=0
    with gzip.open(tp,'rt') as fh:
        for line in fh:
            f=line.rstrip().split('\t')
            if line.startswith('#'):
                for i,c in enumerate(f):
                    if re.fullmatch(r'\d+X',c.strip()):idx.append(i);names.append(c.strip())
                sums=[0]*len(idx);continue
            if not idx:continue
            total+=int(f[2])-int(f[1])
            for j,i in enumerate(idx):sums[j]+=int(f[i])
    if total:
        for name,n in zip(names,sums):m[f'target_bases_ge_{name}_pct']=round(100*n/total,4)
for line in Path(stats).read_text().splitlines():
    f=line.split('\t')
    if f[0]=='SN' and len(f)>=4:
        key={'number of records':'raw_variant_records','number of SNPs':'raw_snps','number of indels':'raw_indels','number of multiallelic sites':'raw_multiallelic_sites'}.get(f[2].rstrip(':'))
        if key:
            try:m[key]=int(f[3])
            except ValueError:m[key]=f[3]
    elif f[0]=='TSTV' and len(f)>=5:
        try:m['raw_ts_tv']=float(f[4])
        except ValueError:pass
with open(out,'w') as fh:json.dump(m,fh,ensure_ascii=False,indent=2);fh.write('\n')
PYMETRICS
if [[ -s "$METRICS_JSON" ]]; then vpass "metrics_json" "$METRICS_JSON"; else vfail "metrics_json" "not created"; fi

printf 'artifact_type\tpath\tbytes\tsha256\n' > "$ARTIFACT_TSV"
add_artifact() {
  local type="$1" file="$2" checksum="${3:-0}" sum=""
  [[ -s "$file" ]] || return 0
  if [[ "$checksum" -eq 1 ]]; then sum="$(sha256sum "$file" | awk '{print $1}')"; fi
  printf '%s\t%s\t%s\t%s\n' "$type" "$file" "$(stat -c %s "$file")" "$sum" >> "$ARTIFACT_TSV"
}
add_artifact sorted_bam "$SORTED_BAM" 0
add_artifact markdup_bam "$MARKDUP_BAM" 0
add_artifact analysis_ready_bam "$FINAL_BAM" 1
add_artifact analysis_ready_bai "${FINAL_BAM}.bai" 1
add_artifact gvcf "$GVCF" 1
add_artifact gvcf_tbi "${GVCF}.tbi" 1
add_artifact raw_vcf "$RAW_VCF" 1
add_artifact raw_vcf_tbi "${RAW_VCF}.tbi" 1
add_artifact metrics_json "$METRICS_JSON" 1
add_artifact final_validation "$FINAL_VALIDATION" 0
vpass "artifact_manifest" "$ARTIFACT_TSV"

RUN_END_EPOCH="$(date +%s)"
python3 - "$PROVENANCE_JSON" <<PYPROV
import json
obj={"pipeline_name":"$PIPELINE_NAME","pipeline_version":"$PIPELINE_VERSION","run_id":"$RUN_ID","status":"COMPLETED" if int("${#V_FAIL[@]}")==0 else "FAILED_VALIDATION","started_epoch":int("$RUN_START_EPOCH"),"finished_epoch":int("$RUN_END_EPOCH"),"elapsed_seconds":int("$RUN_END_EPOCH")-int("$RUN_START_EPOCH"),"run_config":"$RUN_CONFIG_JSON","software_versions":"$VERSIONS_TXT","resource_checksums":"$RESOURCE_SHA256","commands":"$COMMANDS_SH","stage_status":"$STATUS_TSV","execution_trace":"$TRACE_TSV","metrics":"$METRICS_JSON","artifacts":"$ARTIFACT_TSV","final_validation":"$FINAL_VALIDATION"}
with open("$PROVENANCE_JSON","w") as f:json.dump(obj,f,ensure_ascii=False,indent=2);f.write("\n")
PYPROV

printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$CURRENT_STAGE" "$([[ ${#V_FAIL[@]} -eq 0 ]] && echo COMPLETED || echo FAILED)" "$([[ ${#V_FAIL[@]} -eq 0 ]] && echo 0 || echo 1)" >> "$STATUS_TSV"

log "FINAL VALIDATION: PASS=${#V_PASS[@]} WARN=${#V_WARN[@]} FAIL=${#V_FAIL[@]}"
if (( ${#V_WARN[@]} > 0 )); then printf 'WARN: %s\n' "${V_WARN[@]}"; fi
if (( ${#V_FAIL[@]} > 0 )); then
  printf 'FAIL: %s\n' "${V_FAIL[@]}"
  printf 'FAILED\n' > "$LOG_DIR/RUN_FAILED"
  log "Validation failed. Do not use the result until all FAIL items are resolved: $FINAL_VALIDATION"
  exit 1
fi

printf 'COMPLETED\n' > "$LOG_DIR/RUN_COMPLETED"
ln -sfn "$LOG_DIR" "$PROJECT/logs/full/latest_v5"
log "PIPELINE COMPLETED"
log "Run ID             : $RUN_ID"
log "Analysis-ready BAM : $FINAL_BAM"
log "gVCF               : $GVCF"
log "Raw VCF            : $RAW_VCF ($RAW_RECORDS records)"
log "Metrics JSON       : $METRICS_JSON"
log "Validation report  : $FINAL_VALIDATION"
log "Artifact manifest  : $ARTIFACT_TSV"
log "Provenance         : $PROVENANCE_JSON"
log "Pipeline log       : $PIPELINE_LOG"
exit 0

# ==================================================================
# KMG - Coverage QC
# ==================================================================

#!/usr/bin/env bash
# =============================================================================
#  05_coverage_qc.sh — Coverage QC (mosdepth + samtools flagstat) [추가 단계]
#
#  [웹 연동 호출 방식]
#    # 방식 1: 환경변수
#    export SAMPLE_ID="HG002"
#    export INPUT_BAM="/path/to/HG002.recal.bam"
#    bash 05_coverage_qc.sh
#
#    # 방식 2: 인수
#    bash 05_coverage_qc.sh HG002 /path/to/HG002.recal.bam
#
#  [통과 기준]
#    평균 depth >= 80x  /  20x 이상 커버 >= 90%
#    기준 미달 시 exit code 2 반환 (웹 백엔드에서 경고 처리)
# =============================================================================
set -euo pipefail

THREADS="${THREADS:-8}"
BASE_DIR="${BASE_DIR:-$HOME/giab_wes}"
REF_DIR="${BASE_DIR}/ref"

# 유방암 유전자 기본 BED (전용 BED 없을 때 사용)
BREAST_CANCER_BED_CONTENT="chr17\t43044295\t43125483\tBRCA1
chr13\t32315474\t32400266\tBRCA2
chr16\t23603160\t23641310\tPALB2
chr11\t108222484\t108369102\tATM
chr22\t28687743\t28742422\tCHEK2
chr17\t7668402\t7687550\tTP53
chr10\t87863113\t87971930\tPTEN
chr16\t68737292\t68835541\tCDH1"

# ── 입력 결정 ─────────────────────────────────────────────────────────────────
resolve_inputs() {
    if [[ $# -ge 2 ]]; then
        SAMPLE_ID="$1"
        INPUT_BAM="$2"
        return
    fi
    if [[ -n "${SAMPLE_ID:-}" && -n "${INPUT_BAM:-}" ]]; then
        return
    fi
    # 자동 감지: recal.bam
    local FOUND_BAM
    FOUND_BAM=$(find "${BASE_DIR}/samples" -maxdepth 3 \
        -name "*.recal.bam" 2>/dev/null | head -1)
    if [[ -z "${FOUND_BAM}" ]]; then
        echo "ERROR: recal BAM 파일을 찾을 수 없습니다." >&2
        exit 1
    fi
    INPUT_BAM="${FOUND_BAM}"
    local BNAME
    BNAME=$(basename "${FOUND_BAM}")
    SAMPLE_ID="${BNAME%.recal.bam}"
}

# ── Target BED 결정 ───────────────────────────────────────────────────────────
resolve_target_bed() {
    # 우선순위 1: 환경변수로 지정된 캡처 kit BED
    if [[ -n "${TARGET_BED:-}" && -f "${TARGET_BED}" ]]; then
        echo "${TARGET_BED}"
        return
    fi
    # 우선순위 2: ref 디렉토리의 표준 BED
    local STANDARD="${REF_DIR}/exome_targets.bed"
    if [[ -f "${STANDARD}" ]]; then
        echo "${STANDARD}"
        return
    fi
    # 우선순위 3: 기본 유방암 유전자 BED 생성
    local FALLBACK="${BASE_DIR}/ref/breast_cancer_genes.bed"
    mkdir -p "${REF_DIR}"
    printf "${BREAST_CANCER_BED_CONTENT}\n" > "${FALLBACK}"
    echo "  WES 타겟 BED 없음 → 유방암 유전자 BED 사용" >&2
    echo "${FALLBACK}"
}

# ── 커버리지 기준 체크 ────────────────────────────────────────────────────────
check_coverage() {
    local SUMMARY="$1"
    local PASS=true

    while IFS=$'\t' read -r chrom length bases mean min max; do
        if [[ "${chrom}" == "total_region" || "${chrom}" == "total" ]]; then
            local MEAN_INT="${mean%.*}"
            if (( MEAN_INT < 80 )); then
                echo "  WARN: 평균 depth ${mean}x — 80x 미만 (기준 미달)"
                PASS=false
            else
                echo "  PASS: 평균 depth ${mean}x (>= 80x)"
            fi
        fi
    done < "${SUMMARY}"

    if [[ "${PASS}" == "false" ]]; then
        return 2
    fi
    return 0
}

# ── 메인 ──────────────────────────────────────────────────────────────────────
main() {
    resolve_inputs "$@"

    local SAMPLE_DIR="${BASE_DIR}/samples/${SAMPLE_ID}"
    local QC_DIR="${SAMPLE_DIR}/qc/coverage"
    mkdir -p "${QC_DIR}"

    echo "=== [05] Coverage QC ==="
    echo "  Sample ID : ${SAMPLE_ID}"
    echo "  입력 BAM  : ${INPUT_BAM}"

    # 도구 확인
    if ! command -v mosdepth &>/dev/null; then
        echo "  mosdepth 미설치 → conda install 실행..."
        conda install -c bioconda mosdepth -y
    fi

    local TARGET_BED_PATH
    TARGET_BED_PATH=$(resolve_target_bed)
    echo "  타겟 BED  : ${TARGET_BED_PATH}"

    # ── flagstat ──────────────────────────────────────────────────────────────
    echo ""
    echo "=== [05-1] samtools flagstat ==="
    local FLAGSTAT_OUT="${QC_DIR}/${SAMPLE_ID}.flagstat.txt"
    samtools flagstat -@ "${THREADS}" "${INPUT_BAM}" | tee "${FLAGSTAT_OUT}"

    # ── mosdepth ──────────────────────────────────────────────────────────────
    echo ""
    echo "=== [05-2] mosdepth ==="
    local PREFIX="${QC_DIR}/${SAMPLE_ID}"
    mosdepth \
        --by     "${TARGET_BED_PATH}" \
        --threads "${THREADS}" \
        --quantize 0:1:10:20:50:100: \
        "${PREFIX}" \
        "${INPUT_BAM}"

    echo ""
    echo "=== Coverage 요약 ==="
    cat "${PREFIX}.mosdepth.summary.txt"

    echo ""
    echo "기준: 평균 depth >= 80x, 20x 이상 커버 >= 90%"

    # 기준 체크
    local EXIT_CODE=0
    check_coverage "${PREFIX}.mosdepth.summary.txt" || EXIT_CODE=$?

    echo ""
    echo "=== [05] 완료 ==="
    echo "  SAMPLE_ID=${SAMPLE_ID}"
    echo "  FLAGSTAT=${FLAGSTAT_OUT}"
    echo "  MOSDEPTH_SUMMARY=${PREFIX}.mosdepth.summary.txt"
    echo "  COVERAGE_PASS=$([ ${EXIT_CODE} -eq 0 ] && echo true || echo false)"
    echo "  NEXT_STEP=06_variant_calling.sh"

    exit ${EXIT_CODE}
}

main "$@"

# ==================================================================
# KMG - Coverage QC
# ==================================================================







# ==================================================================
# KMG - 9. Intervar
# ==================================================================

#!/usr/bin/env bash
# =============================================================================
#  09_intervar.sh — InterVar ACMG 18기준 자동 분류 [추가 단계]
#
#  [웹 연동 호출 방식]
#    # 방식 1: 환경변수
#    export SAMPLE_ID="HG002"
#    export INPUT_VCF="/path/to/HG002.annotated.vcf"
#    bash 09_intervar.sh
#
#    # 방식 2: 인수
#    bash 09_intervar.sh HG002 /path/to/HG002.annotated.vcf
# =============================================================================
set -euo pipefail

BASE_DIR="${BASE_DIR:-$HOME/giab_wes}"
TOOLS_DIR="${BASE_DIR}/tools"
INTERVAR_DIR="${TOOLS_DIR}/InterVar"

# ── 입력 결정 ─────────────────────────────────────────────────────────────────
resolve_inputs() {
    if [[ $# -ge 2 ]]; then
        SAMPLE_ID="$1"
        INPUT_VCF="$2"
        return
    fi
    if [[ -n "${SAMPLE_ID:-}" && -n "${INPUT_VCF:-}" ]]; then
        return
    fi
    # 자동 감지
    local FOUND_VCF
    FOUND_VCF=$(find "${BASE_DIR}/samples" -maxdepth 4 \
        -name "*.annotated.vcf" 2>/dev/null | head -1)
    if [[ -z "${FOUND_VCF}" ]]; then
        echo "ERROR: annotated VCF 파일을 찾을 수 없습니다." >&2
        exit 1
    fi
    INPUT_VCF="${FOUND_VCF}"
    # 경로에서 Sample ID 추출
    local DIR_NAME
    DIR_NAME=$(dirname "${FOUND_VCF}")
    SAMPLE_ID=$(basename "$(dirname "${DIR_NAME}")")
}

# ── InterVar 설치 ─────────────────────────────────────────────────────────────
install_intervar() {
    if [[ -d "${INTERVAR_DIR}" ]]; then
        echo "  InterVar 이미 설치됨: ${INTERVAR_DIR}"
        return
    fi
    echo "  InterVar 설치 중..."
    mkdir -p "${TOOLS_DIR}"
    git clone https://github.com/WGLab/InterVar.git "${INTERVAR_DIR}"
    cd "${INTERVAR_DIR}"
    pip install -r requirements.txt --break-system-packages 2>/dev/null || true
    echo "  InterVar DB 다운로드 중 (humandb)..."
    python InterVar.py --download_db -d humandb/ -b hg38
    cd - > /dev/null
}

# ── 결과 집계 ────────────────────────────────────────────────────────────────
summarize_results() {
    local RESULT_FILE="$1"
    local OUT_CSV="$2"

    python3 - << PYEOF
import pandas as pd, sys, json

try:
    df = pd.read_csv("${RESULT_FILE}", sep="\t", low_memory=False)

    # ACMG 분류별 집계
    print("\n[ACMG 분류별 변이 수]")
    intervar_col = df["InterVar"] if "InterVar" in df.columns else df.iloc[:, -1]
    counts = intervar_col.value_counts()
    print(counts.to_string())

    # Pathogenic / LP 추출
    patho = df[intervar_col.str.contains("Pathogenic", na=False)]
    print(f"\n[Pathogenic/LP 변이: {len(patho)}개]")

    gene_col = next(
        (c for c in df.columns if "Gene" in c and "refGene" in c), None
    )
    gene_counts = {}
    if gene_col and not patho.empty:
        gene_counts = patho.groupby(gene_col).size().sort_values(ascending=False).to_dict()
        for gene, cnt in gene_counts.items():
            print(f"  {gene}: {cnt}개")

    # CSV 저장
    patho.to_csv("${OUT_CSV}", index=False)
    print(f"\n저장: ${OUT_CSV}")

    # 웹 백엔드용 JSON 요약 출력
    summary = {
        "total_variants": len(df),
        "pathogenic_lp": len(patho),
        "acmg_counts": counts.to_dict(),
        "gene_counts": gene_counts,
    }
    print("\n=== JSON_SUMMARY_START ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print("=== JSON_SUMMARY_END ===")

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── 메인 ──────────────────────────────────────────────────────────────────────
main() {
    resolve_inputs "$@"

    local SAMPLE_DIR="${BASE_DIR}/samples/${SAMPLE_ID}"
    local RESULT_DIR="${SAMPLE_DIR}/results"
    mkdir -p "${RESULT_DIR}"

    echo "=== [09] InterVar ACMG 분류 ==="
    echo "  Sample ID : ${SAMPLE_ID}"
    echo "  입력 VCF  : ${INPUT_VCF}"

    install_intervar

    local OUT_PREFIX="${RESULT_DIR}/${SAMPLE_ID}_intervar"
    local OUT_CSV="${RESULT_DIR}/${SAMPLE_ID}_pathogenic.csv"

    # InterVar 실행
    cd "${INTERVAR_DIR}"
    python InterVar.py \
        -i  "${INPUT_VCF}" \
        --input_type VCF \
        -o  "${OUT_PREFIX}" \
        -b  hg38 \
        -t  intervardb \
        --table_annovar=./table_annovar.pl \
        --convert2annovar=./convert2annovar.pl \
        --annotate_variation=./annotate_variation.pl \
        -d  humandb/
    cd - > /dev/null

    # 결과 파일 경로
    local RESULT_FILE="${OUT_PREFIX}.hg38_multianno.txt.intervar"

    if [[ ! -f "${RESULT_FILE}" ]]; then
        echo "ERROR: InterVar 결과 파일 없음: ${RESULT_FILE}" >&2
        exit 1
    fi

    echo ""
    echo "=== 결과 집계 ==="
    summarize_results "${RESULT_FILE}" "${OUT_CSV}"

    echo ""
    echo "=== [09] 완료 ==="
    echo "  SAMPLE_ID=${SAMPLE_ID}"
    echo "  RESULT_FILE=${RESULT_FILE}"
    echo "  PATHOGENIC_CSV=${OUT_CSV}"
    echo "  NEXT_STEP=10_hapypy_validation.sh"
}

main "$@"
