#!/usr/bin/env bash
# =============================================================================
#  04_markdup_bqsr.sh — GATK MarkDuplicates + BQSR [추가 단계]
#
#  [웹 연동 호출 방식]
#    # 방식 1: 환경변수
#    export SAMPLE_ID="HG002"
#    export INPUT_BAM="/path/to/HG002.sorted.bam"
#    bash 04_markdup_bqsr.sh
#
#    # 방식 2: 인수
#    bash 04_markdup_bqsr.sh HG002 /path/to/HG002.sorted.bam
#
#  [이전 단계에서 자동 연결]
#    03_alignment.sh 출력의 SAMPLE_ID, OUTPUT_BAM을 그대로 받음
# =============================================================================
set -euo pipefail

THREADS="${THREADS:-8}"
BASE_DIR="${BASE_DIR:-$HOME/giab_wes}"
REF_DIR="${BASE_DIR}/ref"
REF="${REF_DIR}/Homo_sapiens_assembly38.fasta"
DBSNP="${REF_DIR}/dbsnp138.vcf"
MILLS="${REF_DIR}/Mills_indels.hg38.vcf.gz"

# ── 입력 결정 ─────────────────────────────────────────────────────────────────
resolve_inputs() {
    # 방식 1: 인수 (SAMPLE_ID, BAM_PATH)
    if [[ $# -ge 2 ]]; then
        SAMPLE_ID="$1"
        INPUT_BAM="$2"
        return
    fi

    # 방식 2: 환경변수
    if [[ -n "${SAMPLE_ID:-}" && -n "${INPUT_BAM:-}" ]]; then
        return
    fi

    # 방식 3: BASE_DIR/samples 에서 자동 감지 (단일 샘플)
    local FOUND_BAM
    FOUND_BAM=$(find "${BASE_DIR}/samples" -maxdepth 3 \
        -name "*.sorted.bam" ! -name "*.markdup.*" \
        2>/dev/null | head -1)

    if [[ -z "${FOUND_BAM}" ]]; then
        echo "ERROR: sorted BAM 파일을 찾을 수 없습니다." >&2
        echo "  SAMPLE_ID, INPUT_BAM 환경변수를 설정하거나 인수로 전달하세요." >&2
        exit 1
    fi

    INPUT_BAM="${FOUND_BAM}"
    # BAM 파일명에서 Sample ID 추출
    local BNAME
    BNAME=$(basename "${FOUND_BAM}")
    SAMPLE_ID="${BNAME%.sorted.bam}"
}

# ── 참조 파일 다운로드 ────────────────────────────────────────────────────────
download_known_sites() {
    mkdir -p "${REF_DIR}"
    if [[ ! -f "${DBSNP}" ]]; then
        echo "  dbSNP 다운로드 중..."
        wget -q -c \
            "https://storage.googleapis.com/genomics-public-data/references/hg38/v0/Homo_sapiens_assembly38.dbsnp138.vcf" \
            -O "${DBSNP}"
        wget -q -c \
            "https://storage.googleapis.com/genomics-public-data/references/hg38/v0/Homo_sapiens_assembly38.dbsnp138.vcf.idx" \
            -O "${DBSNP}.idx"
    fi
    if [[ ! -f "${MILLS}" ]]; then
        echo "  Mills Indels 다운로드 중..."
        wget -q -c \
            "https://storage.googleapis.com/genomics-public-data/references/hg38/v0/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz" \
            -O "${MILLS}"
        wget -q -c \
            "https://storage.googleapis.com/genomics-public-data/references/hg38/v0/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz.tbi" \
            -O "${MILLS}.tbi"
    fi
}

# ── 메인 ──────────────────────────────────────────────────────────────────────
main() {
    resolve_inputs "$@"

    # 출력 경로 (Sample ID 기반)
    local SAMPLE_DIR="${BASE_DIR}/samples/${SAMPLE_ID}"
    local BAM_DIR="${SAMPLE_DIR}/bam"
    mkdir -p "${BAM_DIR}"

    local MD_BAM="${BAM_DIR}/${SAMPLE_ID}.markdup.bam"
    local MD_METRICS="${BAM_DIR}/${SAMPLE_ID}.markdup.metrics.txt"
    local RECAL_TABLE="${BAM_DIR}/${SAMPLE_ID}.recal.table"
    local RECAL_BAM="${BAM_DIR}/${SAMPLE_ID}.recal.bam"

    echo "=== [04] MarkDuplicates + BQSR ==="
    echo "  Sample ID  : ${SAMPLE_ID}"
    echo "  입력 BAM   : ${INPUT_BAM}"

    # 도구 확인
    if ! command -v gatk &>/dev/null; then
        echo "  GATK 미설치 → conda install 실행..."
        conda install -c bioconda gatk4 -y
    fi
    if ! command -v samtools &>/dev/null; then
        conda install -c bioconda samtools -y
    fi

    download_known_sites

    # ── Step 1: MarkDuplicates ────────────────────────────────────────────────
    echo ""
    echo "=== [04-1] MarkDuplicates ==="
    gatk MarkDuplicates \
        -I "${INPUT_BAM}" \
        -O "${MD_BAM}" \
        -M "${MD_METRICS}"
    samtools index "${MD_BAM}"

    # 중복률 파싱
    local DUP_RATE
    DUP_RATE=$(grep -A2 "PERCENT_DUPLICATION" "${MD_METRICS}" \
        | tail -1 | awk '{printf "%.2f%%", $9 * 100}')
    echo "  중복률: ${DUP_RATE}  (10~20%면 정상)"

    # ── Step 2: BaseRecalibrator ──────────────────────────────────────────────
    echo ""
    echo "=== [04-2] BaseRecalibrator ==="
    gatk BaseRecalibrator \
        -I  "${MD_BAM}" \
        -R  "${REF}" \
        --known-sites "${DBSNP}" \
        --known-sites "${MILLS}" \
        -O  "${RECAL_TABLE}"

    # ── Step 3: ApplyBQSR ─────────────────────────────────────────────────────
    echo ""
    echo "=== [04-3] ApplyBQSR ==="
    gatk ApplyBQSR \
        -I  "${MD_BAM}" \
        -R  "${REF}" \
        --bqsr-recal-file "${RECAL_TABLE}" \
        -O  "${RECAL_BAM}"
    samtools index "${RECAL_BAM}"

    echo ""
    echo "=== [04] 완료 ==="
    echo "  SAMPLE_ID=${SAMPLE_ID}"
    echo "  RECAL_BAM=${RECAL_BAM}"
    echo "  DUP_RATE=${DUP_RATE}"
    echo "  NEXT_STEP=05_coverage_qc.sh"
}

main "$@"
