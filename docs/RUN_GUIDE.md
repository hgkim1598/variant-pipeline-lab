# VariantScope 질병 패널 annotation 업그레이드

## 추가된 기능

- PanelApp API 및 버전 고정 JSON 캐시
- PanelApp panel 635, signed-off version 3.0
- Green 유전자 8개 자동 로딩
- Ensembl VEP REST 또는 local VEP 선택
- VEP 유전자와 질병 패널 교집합 계산
- ClinVar, VEP, gnomAD, PanelApp 통합 TSV
- 전체 결과와 패널 결과 분리
- 분석 자원과 옵션을 기록한 manifest JSON
- `region=all` 지원
- allele split 및 선택적 FASTA left-normalization

## 설치

WSL에서 다음 명령을 한 번 실행한다.

```bash
bash /mnt/c/Users/KWON/Documents/Codex/2026-06-25/new-chat-2/outputs/install_panel_upgrade.sh
```

기존 파일은 다음 위치에 백업된다.

```text
/mnt/c/Users/KWON/sproject/scripts/run_vcf_annotation.pre_panel.py
```

## HG002 BRCA1 소규모 검증

공개 HG002 변이 두 개만 Ensembl REST로 보내는 검증 명령이다.

```bash
conda activate variantscope
cd /mnt/c/Users/KWON/sproject

python scripts/run_vcf_annotation.py \
  data/raw/vcf/HG002_GRCh38_v5.0q_smvar.vcf.gz \
  panel \
  results/annotation/HG002_HBOC_panel_v1 \
  data/annotation/clinvar/clinvar_GRCh38_chr.vcf.gz \
  --assembly GRCh38 \
  --filter-preset pass-only \
  --panel-id 635 \
  --panel-version 3.0 \
  --panel-cache data/annotation/panelapp/panel_635_v3.0.json \
  --vep-mode rest
```

## 주요 출력

```text
HG002_HBOC_panel_v1.variants.tsv
HG002_HBOC_panel_v1.panel_variants.tsv
HG002_HBOC_panel_v1.panel.json
HG002_HBOC_panel_v1.manifest.json
HG002_HBOC_panel_v1.clinvar.vcf.gz
HG002_HBOC_panel_v1.vep.cache.json
```

- `variants.tsv`: 품질 필터를 통과한 모든 변이
- `panel_variants.tsv`: 선택한 질병 패널 유전자와 겹치는 변이
- `panel.json`: 분석에 사용된 PanelApp 패널과 유전자
- `manifest.json`: build, 필터 기준, 데이터 버전, API 모드, 결과 수
- `vep.cache.json`: 같은 입력을 재실행할 때 재사용되는 VEP 결과

## 전체 WES 실행

전체 WES 또는 민감한 사람 데이터를 REST API로 보내지 않는다. VEP 116과
GRCh37 cache를 설치한 뒤 다음과 같이 local 모드를 사용한다.

```bash
python scripts/run_vcf_annotation.py \
  input.WES.vcf.gz \
  all \
  results/annotation/sample_HBOC \
  data/annotation/clinvar/clinvar_GRCh37.vcf.gz \
  --assembly GRCh37 \
  --reference-fasta /home/khw/references/b37/human_g1k_v37.fasta \
  --filter-preset balanced \
  --panel-id 635 \
  --panel-version 3.0 \
  --panel-cache data/annotation/panelapp/panel_635_v3.0.json \
  --vep-mode local \
  --vep-dir-cache /home/khw/.vep
```

## 프론트엔드 연결

프론트엔드는 질병명을 직접 분석 코드로 전달하지 않는다.

```text
Inherited breast cancer and ovarian cancer
  -> panel_id=635
  -> panel_version=3.0
```

백엔드는 `panel_variants.tsv`와 `manifest.json`을 읽어 결과를 표시한다.
PanelApp의 새 버전은 자동으로 기존 보고서를 덮어쓰지 않고 관리자가 검토한
뒤 별도 버전으로 등록한다.

## 제한

- 연구·교육용이며 임상 진단 결과가 아니다.
- ClinVar 미등록은 benign을 의미하지 않는다.
- gnomAD 미관찰은 pathogenic을 의미하지 않는다.
- WES small variant 분석만으로 exon-level CNV를 완전히 평가할 수 없다.
- ClinVar VCF의 종합 분류와 질환별 RCV 상세 분류는 구분해야 한다.
