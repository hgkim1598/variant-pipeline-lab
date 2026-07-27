from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPT_CANDIDATES = [
    ROOT / "outputs" / "run_vcf_annotation.py",
    ROOT / "scripts" / "run_vcf_annotation.py",
    ROOT / "script" / "run_vcf_annotation.py",
]
SCRIPT = next((path for path in SCRIPT_CANDIDATES if path.is_file()), None)
assert SCRIPT is not None, f"run_vcf_annotation.py not found under {ROOT}"
SPEC = importlib.util.spec_from_file_location("run_vcf_annotation", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FilterTests(unittest.TestCase):
    def test_balanced_filter(self) -> None:
        expression, thresholds = MODULE.build_filter_expression(
            "balanced", None, None, None
        )
        self.assertEqual(thresholds["min_dp"], 5)
        self.assertIn("FMT/DP>=5", expression)
        self.assertIn("FMT/GQ>=10", expression)
        self.assertIn("FMT/AD[0:1]>=3", expression)

    def test_filter_override(self) -> None:
        expression, thresholds = MODULE.build_filter_expression(
            "balanced", 12, 30, 4
        )
        self.assertEqual(thresholds["min_dp"], 12)
        self.assertIn("FMT/GQ>=30", expression)
        self.assertIn("FMT/AD[0:1]>=4", expression)


class AssemblyInspectionTests(unittest.TestCase):
    def test_clinvar_header_without_contig_length_uses_reference(self) -> None:
        header = "\n".join(
            [
                "##fileformat=VCFv4.1",
                "##reference=GRCh38",
                "##contig=<ID=chr1>",
                "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO",
            ]
        )
        with mock.patch.object(
            MODULE,
            "run_command_capture",
            return_value=header,
        ):
            assembly, uses_chr = MODULE.inspect_vcf_assembly(Path("clinvar.vcf.gz"))
        self.assertEqual(assembly, "GRCh38")
        self.assertTrue(uses_chr)


class PanelTests(unittest.TestCase):
    def test_panel_snapshot(self) -> None:
        path = (
            ROOT
            / "data"
            / "annotation"
            / "panelapp"
            / "panel_635_v3.0.json"
        )
        stored = json.loads(path.read_text(encoding="utf-8"))
        panel = MODULE.normalize_panel_payload(stored, 635, "3.0")
        symbols = {gene["symbol"] for gene in panel["genes"]}
        self.assertEqual(panel["version"], "3.0")
        self.assertEqual(len(symbols), 8)
        self.assertIn("BRCA1", symbols)
        self.assertIn("RAD51D", symbols)

    def test_panelapp_metadata_and_gene_endpoints(self) -> None:
        panel_response = {
            "id": 635,
            "name": "Inherited breast cancer and ovarian cancer",
            "version": "3.0",
        }
        genes_response = {
            "results": [
                {
                    "entity_name": "BRCA1",
                    "confidence_level": "High",
                    "gene_data": {"gene_symbol": "BRCA1"},
                    "mode_of_inheritance": "MONOALLELIC",
                    "phenotypes": ["Breast-ovarian cancer"],
                },
                {
                    "entity_name": "TEST_AMBER",
                    "confidence_level": "Moderate",
                    "gene_data": {"gene_symbol": "TEST_AMBER"},
                },
            ]
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            cache = Path(temp_dir) / "panel.json"
            with mock.patch.object(
                MODULE,
                "json_request",
                side_effect=[panel_response, genes_response],
            ) as request:
                panel = MODULE.load_panel(
                    635,
                    "3.0",
                    "green",
                    cache,
                    False,
                    30,
                )
        self.assertEqual([gene["symbol"] for gene in panel["genes"]], ["BRCA1"])
        requested_urls = [call.args[0] for call in request.call_args_list]
        self.assertIn("/api/v1/panels/635/?", requested_urls[0])
        self.assertIn("/api/v1/panels/635/genes/?", requested_urls[1])

    def test_panel_regions_cover_every_selected_gene(self) -> None:
        panel = {
            "genes": [
                {"symbol": "ATM"},
                {"symbol": "BRCA1"},
            ]
        }
        responses = [
            {
                "id": "ENSG_ATM",
                "assembly_name": "GRCh38",
                "seq_region_name": "11",
                "start": 108222484,
                "end": 108369102,
            },
            {
                "id": "ENSG_BRCA1",
                "assembly_name": "GRCh38",
                "seq_region_name": "17",
                "start": 43044295,
                "end": 43125364,
            },
        ]
        with mock.patch.object(
            MODULE,
            "json_request",
            side_effect=responses,
        ):
            regions = MODULE.resolve_panel_regions(
                panel,
                "GRCh38",
                True,
                30,
            )
        self.assertEqual(
            [item["region"] for item in regions],
            [
                "chr11:108222484-108369102",
                "chr17:43044295-43125364",
            ],
        )


class MergeTests(unittest.TestCase):
    def test_variant_query_allows_missing_genotype_quality_tags(self) -> None:
        output = (
            "chr17\t43044804\tCT\tC\t.\t264856\t30\tBRCA1:672"
            "\tBenign\tBreast_cancer\treviewed_by_expert_panel"
            "\tNC_test:g.1del\t0/1\t.\t.\t.\n"
        )
        with mock.patch.object(
            MODULE,
            "run_command_capture",
            return_value=output,
        ) as capture:
            rows = MODULE.query_variant_rows(Path("input.vcf.gz"), "HG002")
        command = capture.call_args.args[0]
        self.assertIn("--allow-undef-tags", command)
        self.assertEqual(rows[0]["ad"], "")
        self.assertEqual(rows[0]["dp"], "")
        self.assertEqual(rows[0]["gq"], "")

    def test_vep_clinvar_gnomad_panel_merge(self) -> None:
        variant_rows = [
            {
                "chrom": "17",
                "pos": "41251931",
                "ref": "G",
                "alt": "A",
                "filter": "",
                "clinvar_id": "123",
                "qual": "4524.64",
                "geneinfo": "BRCA1:672",
                "clinvar_significance": "Benign",
                "clinvar_disease": "Breast_ovarian_cancer",
                "clinvar_review_status": "reviewed_by_expert_panel",
                "clinvar_hgvs": "NC_test:g.41251931G>A",
                "gt": "0/1",
                "ad": "184,185",
                "dp": "369",
                "gq": "99",
            }
        ]
        vep_results = [
            {
                "input": "17 41251931 . G A . . .",
                "most_severe_consequence": "missense_variant",
                "transcript_consequences": [
                    {
                        "gene_symbol": "BRCA1",
                        "transcript_id": "ENST_TEST",
                        "consequence_terms": ["missense_variant"],
                        "impact": "MODERATE",
                        "canonical": 1,
                        "biotype": "protein_coding",
                        "hgvsc": "ENST_TEST:c.1G>A",
                        "hgvsp": "ENSP_TEST:p.Ala1Thr",
                    }
                ],
                "colocated_variants": [
                    {
                        "frequencies": {
                            "A": {
                                "gnomade": 0.00002,
                                "gnomadg": 0.00001,
                            }
                        }
                    }
                ],
            }
        ]
        panel = {
            "panel_id": 635,
            "name": "Inherited breast cancer and ovarian cancer",
            "version": "3.0",
            "genes": [
                {
                    "symbol": "BRCA1",
                    "confidence": "green",
                    "mode_of_inheritance": "MONOALLELIC",
                    "phenotypes": [],
                }
            ],
        }
        merged = MODULE.build_result_rows(variant_rows, vep_results, panel)
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["gene"], "BRCA1")
        self.assertEqual(merged[0]["in_selected_panel"], "yes")
        self.assertEqual(merged[0]["panel_confidence"], "green")
        self.assertEqual(merged[0]["gnomad_exome_af"], "2e-05")
        self.assertEqual(merged[0]["clinvar_significance"], "Benign")

    def test_non_panel_gene_is_retained_but_flagged(self) -> None:
        variant_rows = [
            {
                "chrom": "7",
                "pos": "140453136",
                "ref": "A",
                "alt": "T",
                "filter": "",
                "clinvar_id": "",
                "qual": "100",
                "geneinfo": "",
                "clinvar_significance": "",
                "clinvar_disease": "",
                "clinvar_review_status": "",
                "clinvar_hgvs": "",
                "gt": "0/1",
                "ad": "10,8",
                "dp": "18",
                "gq": "80",
            }
        ]
        vep_results = [
            {
                "input": "7 140453136 . A T . . .",
                "transcript_consequences": [
                    {
                        "gene_symbol": "BRAF",
                        "transcript_id": "ENST_BRAF",
                        "consequence_terms": ["missense_variant"],
                        "impact": "MODERATE",
                        "canonical": 1,
                    }
                ],
            }
        ]
        panel = {
            "panel_id": 635,
            "name": "Inherited breast cancer and ovarian cancer",
            "version": "3.0",
            "genes": [
                {
                    "symbol": "BRCA1",
                    "confidence": "green",
                    "mode_of_inheritance": "",
                    "phenotypes": [],
                }
            ],
        }
        merged = MODULE.build_result_rows(variant_rows, vep_results, panel)
        self.assertEqual(merged[0]["gene"], "BRAF")
        self.assertEqual(merged[0]["in_selected_panel"], "no")


if __name__ == "__main__":
    unittest.main()
