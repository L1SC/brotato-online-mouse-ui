"""Run real Online LAN mouse UI tests in isolated executables and save folders.

The pack/save/process isolation helpers are reused from the MIT damage-meter
test runner. Only the real installed Online ZIP and the released mouse patch
ZIP are loaded; all interactions use injected Godot input events.
"""
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import time
import uuid
from pathlib import Path

from run_damage_meter_tests import ROOT, check_version, project_settings

MOD_ID = "CoopFix-OnlineMouseUI"
CASES = {
    "baseline": {"host": False, "client1": False},
    "both": {"host": True, "client1": True},
    "host-only": {"host": True, "client1": False},
    "client-only": {"host": False, "client1": True},
    "four-players": {"host": True, "client1": True, "client2": True, "client3": True},
}


def prepare_pack(game, destination, project_name):
    """Copy original resources unchanged except isolated settings/test script."""
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
            "res://tests/mouse_ui_lan_runtime.gd": (ROOT / "tests/mouse_ui_lan_runtime.gd").read_bytes(),
        }
        assert not any(MOD_ID in name for name in resources)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", required=True, type=Path)
    parser.add_argument("--online-zip", type=Path)
    parser.add_argument("--patch-zip", type=Path)
    parser.add_argument("--case", choices=list(CASES) + ["all"], default="both")
    parser.add_argument("--phase", choices=["auto", "selection", "full"], default="auto", help="auto runs full coverage for all-patched cases, selection for baseline/mixed installs")
    parser.add_argument("--timeout", type=int, default=150)
    args = parser.parse_args()
    game = args.game_dir.resolve()
    online = args.online_zip or game.parents[1] / "workshop/content/1942280/3741034628/six666-BrotatoOnline.zip"
    patch = args.patch_zip or ROOT / ("dist/" + MOD_ID + "-1.0.0.zip")
    check_version(online, "six666-BrotatoOnline", "6.6.6")
    selected = CASES if args.case == "all" else {args.case: CASES[args.case]}
    if any(any(installed.values()) for installed in selected.values()):
        check_version(patch, MOD_ID, "1.0.0")
    run_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    output = ROOT / ".local/mouse-ui-tests" / run_id
    output.mkdir(parents=True)
    summary = []
    for case, installed in selected.items():
        phase = ("full" if all(installed.values()) else "selection") if args.phase == "auto" else args.phase
        case_dir = output / case
        case_dir.mkdir()
        processes, logs, packs = [], [], []
        print("Running:", case_dir, flush=True)
        try:
            for role, patched in installed.items():
                runtime = case_dir / ("runtime-" + role)
                mods = runtime / "mods"
                mods.mkdir(parents=True)
                for name in ["Brotato.exe", "steam_api64.dll"]:
                    shutil.copy2(game / name, runtime / name)
                for archive in [online] + ([patch] if patched else []):
                    shutil.copy2(archive, mods / archive.name)
                pack = case_dir / (role + ".pck")
                prepare_pack(game, pack, "BrotatoMouseUITests-" + run_id + "-" + case + "-" + role)
                packs.append(pack)
                log = (case_dir / (role + ".log")).open("wb")
                logs.append(log)
                processes.append(subprocess.Popen([
                    str(runtime / "Brotato.exe"), "--main-pack", str(pack),
                    "--script", "res://tests/mouse_ui_lan_runtime.gd", "--enable-mods",
                    "--no-window", "--audio-driver", "Dummy", "--video-driver", "GLES2",
                    "--mouse-test-role=" + role,
                    "--mouse-test-players=" + str(len(installed)),
                    "--mouse-test-patch=" + ("installed" if patched else "absent"),
                    "--mouse-test-baseline=" + ("yes" if case == "baseline" else "no"),
                    "--mouse-test-phase=" + phase,
                    "--mouse-test-timeout=" + str(args.timeout * 1000 - 5000),
                    "--mouse-test-output=" + str(case_dir / (role + ".json")),
                ], cwd=runtime, stdout=log, stderr=log, creationflags=0x08000000))
            deadline = time.monotonic() + args.timeout
            codes = [process.wait(timeout=max(1, deadline - time.monotonic())) for process in processes]
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            for log in logs:
                log.close()
            for pack in packs:
                pack.unlink(missing_ok=True)
        results = {}
        if codes != [0] * len(installed):
            print("Runtime exit codes:", dict(zip(installed, codes)), flush=True)
        for role in installed:
            result_path = case_dir / (role + ".json")
            if not result_path.exists():
                raise AssertionError("No runtime result for " + role + "; inspect " + str(case_dir / (role + ".log")))
            results[role] = json.loads(result_path.read_text(encoding="utf-8"))
        row = {"case": case, "phase": phase, "installed": installed, "results": results, "exit_codes": codes}
        row["passed"] = codes == [0] * len(installed) and all(r["passed"] for r in results.values())
        summary.append(row)
        (output / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print(json.dumps({"case": case, "passed": row["passed"], "checks": {role: r["checks"] for role, r in results.items()}, "failures": {role: r["failures"] for role, r in results.items()}}), flush=True)
        assert row["passed"], (case, "inspect logs/results", case_dir)
        assert len({r["session_id"] for r in results.values()}) == 1
        assert {index for r in results.values() for index in r["local_player_indices"]} == set(range(len(installed)))
        assert all(r["patch_installed"] == installed[role] for role, r in results.items())
    print("MOUSE_UI_INSTALL_MATRIX_PASSED", output, flush=True)


if __name__ == "__main__":
    main()
