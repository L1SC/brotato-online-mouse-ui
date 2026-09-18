"""Run isolated real-engine LAN tests; no real installation or saves are touched."""
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import time
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def project_settings(data, name):
    """MIT FullMapCamera helper: preserve class/autoload settings, isolate saves."""
    count = struct.unpack_from("<I", data, 4)[0]
    cursor = 8
    settings = {}
    for _ in range(count):
        size = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        key = data[cursor:cursor + size]
        cursor += size
        size = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        settings[key] = data[cursor:cursor + size]
        cursor += size
    for key, value in [(b"application/config/name", name), (b"_custom_features", "")]:
        encoded = value.encode()
        settings[key] = struct.pack("<II", 4, len(encoded)) + encoded + b"\0" * (-len(encoded) % 4)
    output = b"ECFG" + struct.pack("<I", len(settings))
    for key, value in settings.items():
        output += struct.pack("<I", len(key)) + key + struct.pack("<I", len(value)) + value
    return output

MOD_ID = "CoopFix-OnlineDamageMeter"
CASES = {
    "baseline": {"host": False, "client1": False},
    "client-only": {"host": False, "client1": True},
    "both": {"host": True, "client1": True},
    "host-only": {"host": True, "client1": False},
    "four-players": {"host": True, "client1": True, "client2": True, "client3": True},
}


def prepare_pack(game, destination, project_name):
    """Overlay only project isolation and this test, never unpacked mod source."""
    resources = {}
    with (game / "Brotato.pck").open("rb") as source:
        header = source.read(84)
        count = struct.unpack("<I", source.read(4))[0]
        for _ in range(count):
            size = struct.unpack("<I", source.read(4))[0]
            name = source.read(size).rstrip(b"\0").decode()
            offset, size = struct.unpack("<QQ", source.read(16))
            resources[name] = (offset, size, source.read(16))
        offset, size, _ = resources.pop("res://project.binary")
        source.seek(offset)
        overlays = {
            "res://project.binary": project_settings(source.read(size), project_name),
            "res://tests/damage_meter_lan_runtime.gd": (ROOT / "tests/damage_meter_lan_runtime.gd").read_bytes(),
        }
        assert not any(MOD_ID in name for name in resources), "original game pack unexpectedly contains the patch"
        for name in overlays:
            resources.pop(name, None)
        names = sorted(resources.keys() | overlays.keys())
        paths = {name: name.encode() + b"\0" * (-len(name.encode()) % 4) for name in names}
        offset = 88 + sum(4 + len(paths[name]) + 32 for name in names)
        index = []
        for name in names:
            if name in overlays:
                size, digest = len(overlays[name]), hashlib.md5(overlays[name]).digest()
            else:
                _, size, digest = resources[name]
            index.append(struct.pack("<I", len(paths[name])) + paths[name] + struct.pack("<QQ", offset, size) + digest)
            offset += size
        with destination.open("wb") as output:
            output.write(header + struct.pack("<I", len(names)) + b"".join(index))
            for name in names:
                if name in overlays:
                    output.write(overlays[name])
                else:
                    offset, size, _ = resources[name]
                    source.seek(offset)
                    output.write(source.read(size))


def check_version(path, mod_id, version):
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read("mods-unpacked/" + mod_id + "/manifest.json"))
        assert manifest["namespace"] + "-" + manifest["name"] == mod_id, path
        assert manifest["version_number"] == version, (path, manifest["version_number"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", required=True, type=Path)
    parser.add_argument("--online-zip", type=Path)
    parser.add_argument("--dmgmeter-zip", type=Path)
    parser.add_argument("--case", choices=list(CASES) + ["all"], default="all")
    parser.add_argument("--lifecycle", action="store_true", help="also exercise the experimental end-wave/retry harness")
    args = parser.parse_args()
    game = args.game_dir.resolve()
    workshop = game.parents[1] / "workshop/content/1942280"
    online = args.online_zip or workshop / "3741034628/six666-BrotatoOnline.zip"
    meter = args.dmgmeter_zip or workshop / "3358859974/DmgMeter.zip"
    patch = ROOT / ("dist/" + MOD_ID + "-1.0.0.zip")
    check_version(online, "six666-BrotatoOnline", "6.6.6")
    check_version(meter, "lrueckert-DmgMeter", "2.2.0")
    selected = CASES if args.case == "all" else {args.case: CASES[args.case]}
    if any(any(installed.values()) for installed in selected.values()):
        check_version(patch, MOD_ID, "1.0.0")
    run_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    output = ROOT / ".local/damage-meter-tests" / run_id
    output.mkdir(parents=True)
    summary = []
    for case, installed in selected.items():
        case_dir = output / case
        case_dir.mkdir()
        processes, logs, packs = [], [], []
        try:
            for role, patched in installed.items():
                runtime = case_dir / ("runtime-" + role)
                mods = runtime / "mods"
                mods.mkdir(parents=True)
                for name in ["Brotato.exe", "steam_api64.dll"]:
                    shutil.copy2(game / name, runtime / name)
                for archive in [online, meter] + ([patch] if patched else []):
                    shutil.copy2(archive, mods / archive.name)
                pack = case_dir / (role + ".pck")
                prepare_pack(game, pack, "BrotatoDamageMeterTests-" + run_id + "-" + case + "-" + role)
                packs.append(pack)
                log = (case_dir / (role + ".log")).open("wb")
                logs.append(log)
                processes.append(subprocess.Popen([
                    str(runtime / "Brotato.exe"), "--main-pack", str(pack),
                    "--script", "res://tests/damage_meter_lan_runtime.gd", "--enable-mods",
                    "--no-window", "--audio-driver", "Dummy", "--video-driver", "GLES2",
                    "--dm-test-role=" + role,
                    "--dm-test-players=" + str(len(installed)),
                    "--dm-test-patch=" + ("installed" if patched else "absent"),
                    "--dm-test-lifecycle=" + ("yes" if args.lifecycle and case == "client-only" else "no"),
                    "--dm-test-output=" + str(case_dir / (role + ".json")),
                ], cwd=runtime, stdout=log, stderr=log, creationflags=0x08000000))
            codes = [process.wait(timeout=90) for process in processes]
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            for log in logs:
                log.close()
            for pack in packs:
                pack.unlink(missing_ok=True)
        print("Results:", case_dir, flush=True)
        results = {role: json.loads((case_dir / (role + ".json")).read_text()) for role in installed}
        assert codes == [0] * len(installed), (case, codes)
        assert len({r["session_id"] for r in results.values()}) == 1, case
        assert {index for r in results.values() for index in r["local_player_indices"]} == set(range(len(installed))), case
        for role, result in results.items():
            assert result["passed"] and not result["failures"], (case, role, result["failures"])
            assert result["patch_installed"] == installed[role], (case, role)
            assert result["normal_prepare_commit"], (case, role)
            expected_samples = 3 if case == "client-only" and args.lifecycle else 1
            assert len(result["damage_samples"]) == expected_samples, (case, role)
            if case == "client-only" and args.lifecycle:
                assert result["next_wave_verified"] and result["retry_verified"], (case, role)
        row = {"case": case, "installed": installed, "results": results, "passed": True}
        summary.append(row)
        print(json.dumps({"case": case, "passed": True, "checks": {role: r["checks"] for role, r in results.items()}}), flush=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("DAMAGE_METER_INSTALL_MATRIX_PASSED", output, flush=True)


if __name__ == "__main__":
    main()
