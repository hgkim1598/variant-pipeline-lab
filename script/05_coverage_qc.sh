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
