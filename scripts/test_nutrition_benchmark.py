import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

import nutrition_benchmark as benchmark


class NutritionBenchmarkTests(unittest.TestCase):
    def test_failed_sample_retains_its_id_latency_and_billable_usage(self):
        job_id = str(uuid4())
        replies = [
            {"access_token": "fixture-only"},
            {"id": job_id, "status": "queued"},
            {"id": job_id, "status": "failed", "failure_code": "no_food"},
        ]
        sample = "plate-01"
        references = [{"sample": sample, "group": "single"}]
        obs = benchmark.rows(benchmark.DATA / "observations-meals.csv")[0]
        obs.update(sample=sample, stage="raw")
        with tempfile.TemporaryDirectory() as scratch:
            run = Path(scratch)
            args = SimpleNamespace(
                command="capture",
                api="http://127.0.0.1",
                output=run,
                confirmed=None,
                username=None,
            )
            with (
                patch.object(benchmark, "reference_photo", return_value=b"fixture"),
                patch.object(benchmark, "api", side_effect=replies),
                patch.object(benchmark.time, "sleep"),
            ):
                benchmark.capture(args, references, [obs])
            self.assertEqual(
                json.loads((run / (sample + "-raw.json")).read_text()),
                {"analysis_id": job_id},
            )
            (run / (job_id + ".json")).write_text(json.dumps({"cost_cny": "0.02"}))
            benchmark.attach_metrics(run, run)
            observations = benchmark.rows(run / "observations-meals.csv")
            result = benchmark.score(references, [], observations, [])["raw/all"]
            self.assertEqual(result["states"], {"failed": 1})
            self.assertEqual(result["latency_n"], 1)
            self.assertEqual(result["cost_cny_mean"], 0.02)
            self.assertEqual(result["nutrients"]["energy_kcal"]["n"], 0)

    def test_scoring_separates_zero_reference_unknown_nutrients_and_corrections(self):
        base = benchmark.rows(benchmark.DATA / "observations-meals.csv")[0]
        raw = dict(
            base,
            sample="plate-01",
            stage="raw",
            status="ok",
            carbs_g="0",
            protein_g="2",
            fat_g="",
            energy_kcal="90",
            lookups_unique="2",
            cache_hits_unique="1",
        )
        corrected = dict(
            raw, stage="user_confirmed", protein_g="4", fat_g="0", energy_kcal="100"
        )
        ref = {
            "sample": "plate-01",
            "group": "single",
            "carbs_g": "0",
            "protein_g": "4",
            "fat_g": "0",
            "energy_kcal": "100",
        }
        ref_items = [{"sample": "plate-01", "ingredient_id": "rice", "grams": "100"}]
        item = {
            "sample": "plate-01",
            "stage": "raw",
            "matched_or_missed_or_extra": "matched",
            "reference_ingredient_id": "rice",
            "observed_g": "120",
            "visible_before_inference": "yes",
        }
        shown = dict(
            item,
            reference_ingredient_id="",
            matched_or_missed_or_extra="visible_unlabelled",
        )
        scores = benchmark.score([ref], ref_items, [raw, corrected], [item, shown])
        result = scores["raw/all"]
        self.assertEqual(result["nutrients"]["carbs_g"]["mape_n"], 0)
        self.assertEqual(result["nutrients"]["fat_g"]["n"], 0)
        self.assertEqual(result["nutrients"]["energy_kcal"]["mae"], 10)
        self.assertEqual(result["cache_hit_rate"], 0.5)
        self.assertEqual(result["mass_mae_g"], 20)
        self.assertEqual(result["visibility"]["yes"]["reference"], 1)
        self.assertEqual(result["ingredients"], {"matched": 1, "visible_unlabelled": 1})
        self.assertEqual(
            scores["user_confirmed/single"]["nutrients"]["energy_kcal"]["mae"], 0
        )


if __name__ == "__main__":
    unittest.main()
