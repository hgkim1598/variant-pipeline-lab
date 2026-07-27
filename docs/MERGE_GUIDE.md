# VariantScope Annotation Merge Guide

## 1. 이 모듈의 책임

```text
입력:
bgzip VCF + TBI/CSI index

처리:
입력 검증
→ 범위 추출
→ DP/GQ/AD 필터
→ allele 정규화
→ ClinVar annotation
→ VEP/gnomAD annotation
→ PanelApp 질병 유전자 매칭

출력:
annotated VCF
전체 변이 TSV
질병 패널 변이 TSV
resource manifest JSON
QC stats
```

이 모듈은 BAM→VCF variant calling을 담당하지 않는다. 앞 단계가 생성한 VCF를
입력으로 받으며, UI나 최종 보고서 생성은 출력 TSV와 manifest를 사용한다.

## 2. 팀 저장소 권장 위치

저장소 root를 기준으로 다음 구조를 사용한다.

```text
scripts/
  run_vcf_annotation.py

data/
  annotation/
    panelapp/
      panel_635_v3.0.json

tests/
  test_run_vcf_annotation.py

docs/
  VariantScope_annotation_MERGE_GUIDE.md
  VariantScope_pipeline_UI_processing_report_v1.md
```

ClinVar VCF와 reference FASTA는 크기가 크므로 GitHub에 올리지 않는다. 경로를
환경변수, 설정 파일 또는 실행 인자로 전달한다.

## 3. 고정 entrypoint

```text
scripts/run_vcf_annotation.py
```

팀원이 이 파일명을 바꾸지 않고 orchestrator에서 호출하는 것을 권장한다.

## 4. 입력 계약

### 필수 positional arguments

```text
1. input_vcf
2. region
3. output_prefix
4. clinvar_vcf, 생략 가능
```

### 유전성 유방암·난소암 옵션

```text
--panel-id 635
--panel-version 3.0
--panel-confidence green
```

### GRCh37 WES 옵션

```text
--assembly GRCh37
--reference-fasta /path/to/human_g1k_v37.fasta
--filter-preset balanced
```

## 5. 출력 계약

다음 단계는 파일명을 직접 조합하지 말고 `manifest.json`의 `outputs`를 읽는다.

```text
{output_prefix}.clinvar.vcf.gz
{output_prefix}.variants.tsv
{output_prefix}.panel_variants.tsv
{output_prefix}.panel.json
{output_prefix}.manifest.json
{output_prefix}.vep.cache.json
```

### 다음 모듈에 전달할 파일

| 다음 작업 | 권장 입력 |
|---|---|
| 결과 테이블 UI | `panel_variants.tsv` |
| 전체 변이 UI | `variants.tsv` |
| 실행 요약 UI | `manifest.json` |
| 보고서 생성 | `panel_variants.tsv` + `manifest.json` |
| 재분석/감사 | `clinvar.vcf.gz` + manifest |

## 6. 병합 방식

네 개의 Python 스크립트를 한 파일에 붙이지 않는다. 각 스크립트의 책임을
유지하고 최상위 orchestrator가 순서대로 호출한다.

```python
subprocess.run([...variant_calling...], check=True)
subprocess.run([...run_vcf_annotation.py...], check=True)
subprocess.run([...report_generation...], check=True)
```

권장 순서:

```text
01 입력·VCF 준비
02 filtering 및 annotation, 이 모듈
03 prioritization
04 UI용 JSON 및 보고서
```

## 7. 병합 전 확인

```bash
python -m py_compile scripts/run_vcf_annotation.py
python scripts/run_vcf_annotation.py --help
bcftools --version
```

소규모 테스트 후 다음 파일을 확인한다.

```bash
head results/annotation/HG002_HBOC_panel_v1.panel_variants.tsv
python -m json.tool \
  results/annotation/HG002_HBOC_panel_v1.manifest.json | head -n 40
```

## 8. Git 브랜치 권장

```bash
git checkout -b feature/disease-panel-annotation
git add scripts/run_vcf_annotation.py
git add data/annotation/panelapp/panel_635_v3.0.json
git add tests/test_run_vcf_annotation.py
git add docs/
git commit -m "Add disease-panel VCF annotation pipeline"
git push -u origin feature/disease-panel-annotation
```

Pull Request에는 다음을 적는다.

```text
Input: bgzip VCF + index
Output: annotated VCF, variants TSV, panel TSV, manifest
Assembly tested: GRCh37
Filter tested: balanced
Panel: PanelApp 635 v3.0
Unit tests: 6 passed
Live WSL integration test: pending/completed
```

## 9. GitHub에 올리지 않을 파일

```text
*.bam
*.bai
*.vcf.gz
*.vcf.gz.tbi
*.vcf.gz.csi
reference FASTA
VEP cache
ClinVar full VCF
```

PanelApp JSON과 작은 테스트 fixture만 Git에 포함한다.

## 10. 병합 시 변경하면 안 되는 항목

- `GRCh37` 입력에 `GRCh38` ClinVar를 연결하지 않는다.
- `1`과 `chr1` contig 형식을 섞지 않는다.
- `output_prefix` 규칙을 임의로 바꾸지 않는다.
- PanelApp version을 `latest`로만 저장하지 않는다.
- ClinVar 미등록을 benign으로 변환하지 않는다.
- 전체 WES 또는 민감 데이터를 VEP REST로 보내지 않는다.
