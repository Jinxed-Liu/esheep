import unittest
from datetime import datetime, timedelta, timezone
from refresh_esheep_cloud_checkpoints import checkpoint_due


class RefreshPolicyTests(unittest.TestCase):
    def test_each_farm_uses_its_own_boundary(self):
        now = datetime.now(timezone.utc)
        fresh = dict(event_head=100, boundary_event_sequence=100, verified_at=(now-timedelta(days=30)).isoformat())
        self.assertFalse(checkpoint_due(fresh, now=now))
        self.assertTrue(checkpoint_due(dict(fresh, boundary_event_sequence=None), now=now))
        self.assertTrue(checkpoint_due(dict(fresh, boundary_event_sequence=99), now=now))
        self.assertFalse(checkpoint_due(dict(fresh, event_head=101, verified_at=now.isoformat()), now=now))
        self.assertTrue(checkpoint_due(dict(fresh, event_head=600, verified_at=now.isoformat()), now=now))


if __name__ == '__main__':
    unittest.main()
