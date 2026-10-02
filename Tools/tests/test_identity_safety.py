import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "check-identity-safety.py"


class IdentitySafetyTests(unittest.TestCase):
    def check(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Example.swift").write_text(source, encoding="utf-8")
            return subprocess.run([sys.executable, str(SCRIPT), "--source-root", str(root)],
                                  capture_output=True, text=True)

    def test_rejects_normal_generic_and_inferred_trapping_constructors(self):
        for constructor in ("Dictionary(uniqueKeysWithValues: pairs)",
                            "Dictionary<UUID, Image>(uniqueKeysWithValues: pairs)",
                            ".init(\n    uniqueKeysWithValues\n    : pairs)"):
            with self.subTest(constructor=constructor):
                result = self.check("let index = " + constructor)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Example.swift:", result.stderr)
                self.assertIn("explicit duplicate-key policy", result.stderr)

    def test_accepts_explicit_policies_and_grouping(self):
        result = self.check("""
            let index = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            let groups = Dictionary(grouping: items, by: { $0.id })
            """)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_source_directory_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPT), "--source-root",
                                     str(Path(directory) / "missing")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("source directory is missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
