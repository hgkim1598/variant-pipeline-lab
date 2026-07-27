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
