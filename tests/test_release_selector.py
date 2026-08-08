import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

SELECTOR_PATH = Path(__file__).parents[1] / "lib" / "release_selector.py"


def load_selector_module():
    spec = importlib.util.spec_from_file_location("release_selector", SELECTOR_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ReleaseSelectorTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.selector = load_selector_module()

    def test_release_candidate_selects_highest_semantic_version(self):
        tags = [
            {"name": "release/1.9.0-rc.20", "commit": {"sha": "old-version"}},
            {"name": "release/1.10.0-rc.2", "commit": {"sha": "old-candidate"}},
            {"name": "release/1.10.0-rc.10", "commit": {"sha": "new"}},
            {"name": "release/1.10.0", "commit": {"sha": "production"}},
            {"name": "release/rc9.9.9", "commit": {"sha": "old-rc-format"}},
            {"name": "release/2.0.0", "commit": {"sha": "production"}},
            {"name": "RELEASE-9.9.9", "commit": {"sha": "legacy"}},
        ]

        selected = self.selector.select_release(tags, "release-candidate")

        self.assertEqual(selected.tag, "release/1.10.0-rc.10")
        self.assertEqual(selected.version, "1.10.0-rc.10")
        self.assertEqual(selected.sha, "new")

    def test_production_excludes_release_candidates_and_legacy_tags(self):
        tags = [
            {"name": "release/9.0.0-rc.1", "commit": {"sha": "candidate"}},
            {"name": "release/rc10.0.0", "commit": {"sha": "old-rc-format"}},
            {"name": "RELEASE-10.0.0", "commit": {"sha": "legacy"}},
            {"name": "release/2.9.0", "commit": {"sha": "old"}},
            {"name": "release/2.10.0", "commit": {"sha": "new"}},
        ]

        selected = self.selector.select_release(tags, "production")

        self.assertEqual(selected.tag, "release/2.10.0")
        self.assertEqual(selected.version, "2.10.0")
        self.assertEqual(selected.sha, "new")

    def test_release_candidate_rejects_non_semver_numeric_identifiers(self):
        invalid_tags = [
            "release/01.0.0-rc.1",
            "release/1.00.0-rc.1",
            "release/1.0.00-rc.1",
            "release/1.0.0-rc.01",
            "release/1.0.0-rc1",
            "release/1.0.0-RC.1",
        ]

        with self.assertRaises(self.selector.NoMatchingRelease):
            self.selector.select_release(
                [{"name": name, "commit": {"sha": "invalid"}} for name in invalid_tags],
                "release-candidate",
            )

    def test_missing_channel_release_fails_closed(self):
        with self.assertRaises(self.selector.NoMatchingRelease):
            self.selector.select_release(
                [{"name": "master", "commit": {"sha": "unsafe"}}],
                "production",
            )

    def test_unknown_channel_is_rejected(self):
        with self.assertRaises(ValueError):
            self.selector.select_release([], "preview")

    def test_master_ancestry_uses_the_compare_merge_base(self):
        comparison = {
            "merge_base_commit": {"sha": "candidate-sha"},
            "status": "ahead",
        }

        self.selector.assert_master_contains(comparison, "candidate-sha")

    def test_diverged_tag_is_rejected(self):
        comparison = {
            "merge_base_commit": {"sha": "another-commit"},
            "status": "diverged",
        }

        with self.assertRaises(self.selector.TagNotOnMaster):
            self.selector.assert_master_contains(comparison, "candidate-sha")

    def test_cli_outputs_machine_readable_selection(self):
        result = subprocess.run(
            [sys.executable, str(SELECTOR_PATH), "--channel", "production"],
            input=json.dumps(
                [{"name": "release/3.1.4", "commit": {"sha": "commit-sha"}}]
            ),
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            json.loads(result.stdout),
            {"sha": "commit-sha", "tag": "release/3.1.4", "version": "3.1.4"},
        )


if __name__ == "__main__":
    unittest.main()
