"""Regression coverage for signed input preservation and SQL-text growth."""
import copy
import json
import re
import unittest

from repair_esheep_cloud_v2_history import staged_command_batches

FARM = "00000000-0000-0000-0000-000000000001"
OWNER = "00000000-0000-0000-0000-000000000002"


class CommandStagingTests(unittest.TestCase):
    def test_preserves_every_signed_envelope_and_order_across_batches(self):
        commands = [{"unsigned_command_base64": "YWJj" + str(index),
                     "device_signature_base64": "c2ln", "content_digest": str(index),
                     "fixture": "羊场 O'Brien \\ 路径\n"} for index in range(503)]
        before = copy.deepcopy(commands)
        sql = staged_command_batches(commands, FARM, 3, OWNER)
        inputs = re.findall(r"jsonb_array_elements\('((?:''|[^'])*)'::jsonb\)", sql)
        batches = [json.loads(value.replace("''", "'")) for value in inputs]
        self.assertEqual([len(batch) for batch in batches], [250, 250, 3])
        self.assertEqual([command for batch in batches for command in batch], before)
        self.assertEqual(commands, before)
        self.assertIn("ORDER BY ordinal", sql)

    def test_large_payload_never_enters_retained_utility_statements(self):
        marker = "oversized-envelope-" + "x" * 1_000_000
        sql = staged_command_batches([{"unsigned_command_base64": marker}], FARM, 3, OWNER)
        utility = re.findall(r"DO \$\$.*?END \$\$;", sql, flags=re.S)
        self.assertEqual(len(utility), 1)
        self.assertLess(len(utility[0].encode()), 2048)
        self.assertNotIn(marker, utility[0])
        self.assertIn("INSERT INTO pg_temp.esheep_repair_command_input", sql)
        self.assertNotIn("CREATE TEMP TABLE esheep_repair_command_input AS", sql)

    def test_keeps_audited_command_path_and_caller_transaction(self):
        sql = staged_command_batches([{}], FARM, 3, OWNER,
                                     rejection_message="forward repair rejected")
        self.assertIn(f"esheep_cloud.process_command_v2('{FARM}',3,'{OWNER}',c)", sql)
        self.assertIn("IF r->>'type'<>'accepted' THEN RAISE EXCEPTION 'forward repair rejected: %',r", sql)
        self.assertIn("ON COMMIT DROP", sql)
        self.assertIn("DROP TABLE pg_temp.esheep_repair_command_input", sql)
        self.assertNotRegex(sql, r"(?im)^\s*(BEGIN|COMMIT|ROLLBACK);\s*$")

    def test_rejects_invalid_generation_batch_size_or_identity(self):
        for options in ({"generation": 0}, {"generation": True}, {"batch_size": 0},
                        {"batch_size": 251}, {"farm_id": "not-a-uuid"}):
            args = {"commands": [{}], "farm_id": FARM, "generation": 3, "owner_id": OWNER, **options}
            with self.subTest(options=options), self.assertRaises(ValueError):
                staged_command_batches(**args)


if __name__ == "__main__":
    unittest.main()
