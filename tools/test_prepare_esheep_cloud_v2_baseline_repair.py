import copy
import unittest

from prepare_esheep_cloud_v2_baseline_repair import translate

SHEEP = "00000000-0000-0000-0000-000000000001"
TRANSFER = "00000000-0000-0000-0000-000000000002"
PEN = "00000000-0000-0000-0000-000000000003"


class ApprovedOperationTranslationTests(unittest.TestCase):
    def test_transfer_keeps_backfill_time_record_id_and_location_lane(self):
        payload = {"kind": "transferSheep", "identifiers": {"sheepID": SHEEP},
                   "optionalIdentifiers": {"toPenID": PEN},
                   "dates": {"occurredAt": "2026-07-10T06:58:00Z"},
                   "strings": {"note": "真实补录"}}
        before = copy.deepcopy(payload)
        kind, body, streams, fields, occurred = translate(payload, TRANSFER)
        self.assertEqual(kind, "transfer.record")
        self.assertEqual(body["transferSheep"]["toPenID"], PEN)
        self.assertEqual(occurred, 1783666680000)
        self.assertEqual(streams, [{"type": "transfer", "id": TRANSFER},
                                  {"type": "sheepLocation", "id": SHEEP}])
        self.assertEqual(fields, [])
        self.assertEqual(payload, before)

    def test_purpose_preserves_reason_and_original_revision(self):
        care = {"setSheepPurpose": {"sheepID": SHEEP, "purpose": "繁殖母羊",
                                    "reason": "后备母羊配种", "expectedRevision": 2}}
        result = translate({"kind": "care", "careCommand": care,
                            "dates": {"sheepPurposeChangedAt": "2026-09-04T07:00:21Z"}}, SHEEP)
        self.assertEqual(result[0], "care.sheep.setPurpose")
        self.assertEqual(result[1], care)
        self.assertEqual(result[3], ["purpose"])
        self.assertEqual(result[4], 1788505221000)

    def test_pedigree_preserves_full_approved_draft(self):
        care = {"updateSheepPedigree": {"_0": {"id": TRANSFER, "sheepID": SHEEP,
                "damID": PEN, "expectedRevision": 3, "reason": "核对后确认"}}}
        result = translate({"kind": "care", "careCommand": care}, SHEEP)
        self.assertEqual(result[0], "care.sheepPedigree.update")
        self.assertEqual(result[1], care)
        self.assertIsNone(result[4])

    def test_rejects_unknown_operation(self):
        with self.assertRaises(ValueError):
            translate({"kind": "removeSheep"}, SHEEP)

    def test_rejects_target_mismatch(self):
        with self.assertRaises(ValueError):
            translate({"kind": "care", "careCommand": {"setSheepPurpose": {
                "sheepID": PEN, "purpose": "繁殖母羊"}}}, SHEEP)

    def test_rejects_unapproved_purpose(self):
        with self.assertRaises(ValueError):
            translate({"kind": "care", "careCommand": {"setSheepPurpose": {
                "sheepID": SHEEP, "purpose": "育肥羊"}}}, SHEEP)

    def test_rejects_ambiguous_care_body(self):
        with self.assertRaises(ValueError):
            translate({"kind": "care", "careCommand": {
                "setSheepPurpose": {}, "updateSheepPedigree": {}}}, SHEEP)

    def test_rejects_other_care_kind(self):
        with self.assertRaises(ValueError):
            translate({"kind": "care", "careCommand": {"recordHealth": {}}}, SHEEP)


if __name__ == "__main__":
    unittest.main()
