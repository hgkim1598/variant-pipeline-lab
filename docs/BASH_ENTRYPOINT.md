# VariantScope Bash entrypoint

`scripts/run_vcf_annotation.sh` is the stable shell entrypoint for the
annotation module. It validates the local environment, prints the resolved
command, invokes the tested Python analysis core, and lists generated files.

The Python core remains the single implementation of PanelApp, Ensembl VEP,
gnomAD, ClinVar, normalization, filtering, and TSV/manifest generation. This
prevents the Bash and Python paths from producing different scientific results.

## Install

```bash
bash /mnt/c/Users/KWON/Documents/Codex/2026-06-25/new-chat-2/outputs/install_panel_upgrade.sh
```

## Run the inherited breast and ovarian cancer panel

```bash
conda activate variantscope
cd /mnt/c/Users/KWON/sproject

bash scripts/run_vcf_annotation.sh \
  data/raw/vcf/HG002_GRCh38_v5.0q_smvar.vcf.gz \
  panel \
  results/annotation/HG002_HBOC_panel_bash \
  data/annotation/clinvar/clinvar_GRCh38_chr.vcf.gz \
  --assembly GRCh38 \
  --filter-preset pass-only \
  --panel-id 635 \
  --panel-version 3.0 \
  --panel-confidence green \
  --vep-mode rest
```

## Show help

```bash
bash scripts/run_vcf_annotation.sh --help
```

Set `PYTHON_BIN` only when a non-default Python executable is required:

```bash
PYTHON_BIN=/path/to/python bash scripts/run_vcf_annotation.sh ...
```
