"""Package the mouse patch and its explicit source/test file list.

Packaging/checksum helpers are reused from this project's MIT damage-meter
builder. No game resources or prerequisite mod files are redistributed.
"""
import json
import hashlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "mods-unpacked/CoopFix-OnlineMouseUI"
DOCS = ["docs/online-mouse-ui.md", "docs/online-mouse-ui-verification.md"]
SUPPORT = [
    "LICENSE", "tools/build_mouse_ui.py",
    "tools/run_mouse_ui_tests.py", "tools/run_damage_meter_tests.py",
    "tests/mouse_ui_lan_runtime.gd",
    "tests/mouse_ui_test_lan_transport.gd",
]


def finish(path):
    # Reused from the MIT damage-meter builder; kept standalone for source ZIPs.
    with ZipFile(path) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(set(archive.namelist()))
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    path.with_suffix(path.suffix + ".sha256").write_text(f"{digest}  {path.name}\n", encoding="utf-8")
    print(path)


def main():
    version = json.loads((MOD / "manifest.json").read_text(encoding="utf-8"))["version_number"]
    files = sorted(p for p in MOD.rglob("*") if p.is_file())
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    install = dist / f"{MOD.name}-{version}.zip"
    with ZipFile(install, "w", compression=ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, path.relative_to(ROOT).as_posix())
        for index, name in enumerate(DOCS):
            archive.write(ROOT / name, f"mods-unpacked/{MOD.name}/" + ("README.md" if index == 0 else "online-mouse-ui-verification.md"))
    finish(install)
    source = dist / f"{MOD.name}-{version}-source.zip"
    with ZipFile(source, "w", compression=ZIP_DEFLATED) as archive:
        for path in files + [ROOT / name for name in DOCS + SUPPORT]:
            archive.write(path, path.relative_to(ROOT).as_posix())
    finish(source)


if __name__ == "__main__":
    main()
