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
