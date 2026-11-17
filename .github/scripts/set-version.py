from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

version = sys.argv[1]
match = re.fullmatch(r"([2-9][0-9]{3})\.([1-9]|1[0-2])\.([1-9][0-9]*)", version)
if not match or int(match[3]) > 4294967295:
    raise SystemExit("expected year.month.sequence")

for name in ("package.xml", "package_ros1.xml", "package_ros2.xml"):
    path = Path(name)
    content, count = re.subn(r"<version>[^<]+</version>", f"<version>{version}</version>", path.read_text())
    if count != 1 or ET.fromstring(content).findtext("version") != version:
        raise SystemExit(f"invalid package version: {name}")
    path.write_text(content)
Path("VERSION").write_text(version + "\n")
