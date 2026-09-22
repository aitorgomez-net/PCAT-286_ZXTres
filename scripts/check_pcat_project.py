#!/usr/bin/env python3
"""Check the single PCAT-286 AT Quartus manifest and its active top level."""

from __future__ import annotations

import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(text: str, fragment: str, subject: str) -> None:
    if fragment not in text:
        raise SystemExit(f"{subject}: missing required fragment: {fragment}")


def reject(text: str, fragment: str, subject: str) -> None:
    if fragment in text:
        raise SystemExit(f"{subject}: forbidden fragment remains: {fragment}")


def main() -> None:
    qpf_files = sorted(path.name for path in ROOT.glob("*.qpf"))
    qsf_files = sorted(path.name for path in ROOT.glob("*.qsf"))
    if qpf_files != ["PCAT-286.qpf"] or qsf_files != ["PCAT-286.qsf"]:
        raise SystemExit(
            f"project: expected only PCAT-286.qpf/PCAT-286.qsf, "
            f"found qpf={qpf_files} qsf={qsf_files}"
        )

    qpf = (ROOT / "PCAT-286.qpf").read_text(encoding="utf-8")
    qsf = (ROOT / "PCAT-286.qsf").read_text(encoding="utf-8")
    qip = (ROOT / "files.qip").read_text(encoding="utf-8")
    top = (ROOT / "PCAT-286.sv").read_text(encoding="utf-8")
    integration_qip = (
        ROOT / "rtl/spk286_integration/spk286_integration.qip"
    ).read_text(encoding="utf-8")
    common_qip = (ROOT / "rtl/common/common.qip").read_text(encoding="utf-8")

    require(qpf, 'PROJECT_REVISION = "PCAT-286"', "PCAT-286.qpf")
    require(qsf, 'VERILOG_MACRO "AT_PROFILE"', "PCAT-286.qsf")
    require(qsf, "source config.tcl", "PCAT-286.qsf")
    require(qsf, "SYSTEMVERILOG_FILE PCAT-286.sv", "PCAT-286.qsf")
    require(qsf, "source files.qip", "PCAT-286.qsf")
    require(qsf, "PROJECT_OUTPUT_DIRECTORY output_files", "PCAT-286.qsf")
    require(qip, "SDC_FILE SYSTEM.sdc", "files.qip")
    if not (ROOT / "SYSTEM.sdc").is_file():
        raise SystemExit("project: missing canonical SYSTEM.sdc")
    reject(qip, "PCAT-286.sdc", "files.qip")
    require(qip, "rtl/spk286_integration/spk286_integration.qip", "files.qip")
    require(qip, "rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv", "files.qip")
    require(qip, "rtl/KFPC-XT/HDL/KF8253/HDL/KF8253.sv", "files.qip")
    require(qip, "rtl/KFPC-XT/HDL/KF8259/HDL/KF8259.sv", "files.qip")
    reject(qip, "rtl/8088", "files.qip")
    reject(qip, "Chipset_SPK286.sv", "files.qip")
    reject(qip, "Bus_Arbiter_SPK286.sv", "files.qip")

    require(integration_qip, "spk286_microcode_pkg.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_microcode_rom.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_biu.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_machine_cpu.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_at_machine.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_at_video_adapter.sv", "spk286_integration.qip")
    reject(integration_qip, "spk286_at_emu.sv", "spk286_integration.qip")

    require(common_qip, "floppy.v", "rtl/common/common.qip")
    require(common_qip, "simple_fifo.v", "rtl/common/common.qip")
    require(common_qip, "ide.v", "rtl/common/common.qip")
    require(common_qip, "spk286_debug_min_overlay.sv", "rtl/common/common.qip")
    reject(common_qip, "sound", "rtl/common/common.qip")
    reject(common_qip, "MSMouseWrapper", "rtl/common/common.qip")

    require(top, "module emu_at", "PCAT-286.sv")
    require(top, "spk286_at_machine u_at_machine", "PCAT-286.sv")
    require(top, "spk286_at_mister_sdram_owner u_at_sdram_owner", "PCAT-286.sv")
    require(top, "spk286_at_hps_rom_loader u_at_hps_rom_loader", "PCAT-286.sv")
    require(top, '"PCAT-286;"', "PCAT-286.sv")
    reject(top, "module emu\n", "PCAT-286.sv")
    reject(top, "spk286_xt_bridge", "PCAT-286.sv")

    overlay = (ROOT / "rtl/common/spk286_debug_min_overlay.sv").read_text(
        encoding="utf-8"
    )
    require(overlay, "video_sequence", "spk286_debug_min_overlay.sv")
    require(overlay, "fallback_raster", "spk286_debug_min_overlay.sv")
    require(overlay, 'text_at("RASTER:N"', "spk286_debug_min_overlay.sv")
    require(overlay, 'text_at("SNAP:00"', "spk286_debug_min_overlay.sv")

    for required_test in (
        "scripts/test_at_profile_elab.sh",
        "sim/spk286_integration/spk286_at_config_tb.sv",
    ):
        if not (ROOT / required_test).is_file():
            raise SystemExit(f"project: missing required AT test: {required_test}")

    rom = ROOT / "tests/firmware/pcat286_event_diag.rom"
    digest = hashlib.sha256(rom.read_bytes()).hexdigest()
    if rom.stat().st_size != 65536:
        raise SystemExit(f"diagnostic ROM: expected 65536 bytes, got {rom.stat().st_size}")

    print(
        "PCAT_AT_PROJECT_CHECK_PASS "
        f"qpf={qpf_files[0]} qsf={qsf_files[0]} "
        f"rom_size={rom.stat().st_size} rom_sha256={digest}"
    )


if __name__ == "__main__":
    main()
