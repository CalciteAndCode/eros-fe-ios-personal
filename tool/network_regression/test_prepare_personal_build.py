import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class PersonalBuildPreparationTest(unittest.TestCase):
    def test_encrypted_config_can_be_prepared_without_overwriting_user_config(self):
        source_root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix="eros-personal-build-") as temp:
            root = Path(temp)
            (root / "scripts").mkdir()
            (root / "lib/config").mkdir(parents=True)
            script = root / "scripts/prepare_personal_build.py"
            shutil.copy2(source_root / "scripts/prepare_personal_build.py", script)
            sample = b"class FeConfig { static const sentryDsn = ''; }\n"
            (root / "lib/config/config.dart.sample").write_bytes(sample)
            config = root / "lib/config/config.dart"
            config.write_bytes(b"\x00GITCRYPT encrypted bytes")
            result = subprocess.run([sys.executable, str(script)], check=True,
                                    capture_output=True, text=True)
            self.assertIn("Prepared", result.stdout)
            self.assertEqual(config.read_bytes(), sample)
            with (root / "ios/Runner/GoogleService-Info.plist").open("rb") as plist:
                self.assertEqual(plistlib.load(plist), {})
            custom = b"class FeConfig { static const sentryDsn = 'user-config'; }\n"
            config.write_bytes(custom)
            subprocess.run([sys.executable, str(script)], check=True,
                           capture_output=True, text=True)
            self.assertEqual(config.read_bytes(), custom)


if __name__ == "__main__":
    unittest.main()
