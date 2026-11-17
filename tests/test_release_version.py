from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


class ReleaseVersionTest(unittest.TestCase):
    def test_runtime_and_ros_manifests_share_the_release_version(self):
        for version in ("2026.11.1", "2026.12.4294967295", "0.0.0-dev"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory)
                subprocess.run([
                    "cmake", f"-DODINCUDA_VERSION={version}", f"-DODINCUDA_BINARY_DIR={destination}",
                    "-P", str(ROOT / "cmake/Version.cmake"),
                ], check=True, capture_output=True, text=True)
                generated = destination / "generated"
                package_version = "0.0.0" if version == "0.0.0-dev" else version
                for name in ("package.xml", "package_ros1.xml", "package_ros2.xml"):
                    self.assertEqual(ET.parse(generated / name).findtext("version"), package_version)
                program = destination / "version.cpp"
                program.write_text('#include "odincuda_version.hpp"\n#include <cstdio>\nint main() { std::puts(ODINCUDA_VERSION); }\n')
                executable = destination / "version"
                subprocess.run(["c++", "-I", str(generated), str(program), "-o", str(executable)], check=True)
                self.assertEqual(subprocess.check_output([str(executable)], text=True).strip(), version)

    def test_invalid_release_versions_are_rejected(self):
        for version in ("2026.0.1", "2026.01.1", "2026.11.0", "2026.11.4294967296", "2026.11.1-extra"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([
                    "cmake", f"-DODINCUDA_VERSION={version}", f"-DODINCUDA_BINARY_DIR={directory}",
                    "-P", str(ROOT / "cmake/Version.cmake"),
                ], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)

    def test_release_archive_build_uses_embedded_version_without_git(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            shutil.copytree(ROOT / "cmake", source / "cmake")
            for name in ("package.xml", "package_ros1.xml", "package_ros2.xml", "VERSION"):
                shutil.copy2(ROOT / name, source / name)
            subprocess.run(["python3", str(ROOT / ".github/scripts/set-version.py"), "2026.11.3"], cwd=source, check=True)
            subprocess.run(["cmake", f"-DODINCUDA_BINARY_DIR={directory}/build", "-P", str(source / "cmake/Version.cmake")], cwd=source, check=True)
            self.assertEqual(ET.parse(Path(directory) / "build/generated/package.xml").findtext("version"), "2026.11.3")


if __name__ == "__main__":
    unittest.main()
