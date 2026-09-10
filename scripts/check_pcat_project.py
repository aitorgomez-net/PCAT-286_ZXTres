#!/usr/bin/env python3
"""Check the production project manifest and diagnostic-ROM loading contract."""

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
    qsf = (ROOT / "PCAT-286.qsf").read_text(encoding="utf-8")
    qip = (ROOT / "files_pcat286.qip").read_text(encoding="utf-8")
    top = (ROOT / "PCAT-286.sv").read_text(encoding="utf-8")
    integration_qip = (
        ROOT / "rtl/spk286_integration/spk286_integration.qip"
    ).read_text(encoding="utf-8")
    common_qip = (ROOT / "rtl/common/common.qip").read_text(encoding="utf-8")

    require(qsf, "SYSTEMVERILOG_FILE PCAT-286.sv", "PCAT-286.qsf")
    require(qsf, "source files_pcat286.qip", "PCAT-286.qsf")
    require(qsf, "PROJECT_OUTPUT_DIRECTORY output_files_pcat286", "PCAT-286.qsf")
    require(qip, "QIP_FILE rtl/spk286_integration/spk286_integration.qip", "files_pcat286.qip")
    require(qip, 'SYSTEMVERILOG_FILE "rtl/KFPC-XT/HDL/Chipset_SPK286.sv"', "files_pcat286.qip")
    require(qip, 'SYSTEMVERILOG_FILE "rtl/KFPC-XT/HDL/Bus_Arbiter_SPK286.sv"', "files_pcat286.qip")
    reject(qip, "rtl/8088", "files_pcat286.qip")

    require(integration_qip, "spk286_microcode_pkg.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_microcode_rom.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_biu.sv", "spk286_integration.qip")
    require(integration_qip, "spk286_machine_cpu.sv", "spk286_integration.qip")
    require(common_qip, "spk286_debug_overlay.sv", "rtl/common/common.qip")

    require(top, "spk286_machine_cpu u_SPK286", "PCAT-286.sv")
    require(top, "spk286_xt_bridge u_SPK286_XT_BRIDGE", "PCAT-286.sv")
    require(top, "spk286_xt_ownership u_SPK286_XT_OWNERSHIP", "PCAT-286.sv")
    require(top, ".execute_enable         (1'b1)", "PCAT-286.sv")
    reject(top, ".F12KEYMOD(1)", "PCAT-286.sv")
    require(top, "spk286_diag_monitor u_SPK286_DIAG_MONITOR", "PCAT-286.sv")
    require(top, "pcat_rom_loader u_PCAT_ROM_LOADER", "PCAT-286.sv")
    require(top, ".intr                   (interrupt_to_cpu)", "PCAT-286.sv")
    require(top, ".nmi                    (1'b0)", "PCAT-286.sv")
    require(top, ".external_request       (processor_hold_request)", "PCAT-286.sv")
    require(top, "always_ff @(posedge clk_chipset)\n        spk_reset <= reset_cpu", "PCAT-286.sv")
    require(top, ".loader_reset_owner     (spk_reset)", "PCAT-286.sv")
    require(integration_qip, "pcat_rom_loader.sv", "spk286_integration.qip")
    require(top, "P1FC0,ROM,PCAT BIOS:;", "PCAT-286.sv")
    require(top, "assign LED_DISK = diagnostic_pass", "PCAT-286.sv")
    require(top, "assign LED_POWER = 0", "PCAT-286.sv")
    require(top, "P1O[71],SPK286 Debug,Off,On;", "PCAT-286.sv")
    require(top, "spk286_debug_overlay", "PCAT-286.sv")
    require(top, ".src_rst                 (spk_debug_source_reset)", "PCAT-286.sv")
    require(top, ".HS                      (VGA_HS_video_hdmi)", "PCAT-286.sv")
    require(top, ".VS                      (VGA_VS_video_hdmi)", "PCAT-286.sv")
    require(top, "P1O[73:72],Debug Page,CPU,Registers,Bus,Trace;", "PCAT-286.sv")
    require(top, ".trace0                  (spk_debug_trace0)", "PCAT-286.sv")
    reject(top, "i8088 B1", "PCAT-286.sv")
    reject(top, '"P1oV,CPU Type', "PCAT-286.sv")
    reject(top, '"P1oL,Fake 286 FLAGS', "PCAT-286.sv")

    overlay = (ROOT / "rtl/common/spk286_debug_overlay.sv").read_text(
        encoding="utf-8"
    )
    require(overlay, "snapshot_sequence", "spk286_debug_overlay.sv")
    require(overlay, "fallback_raster", "spk286_debug_overlay.sv")
    require(overlay, 'text_at("RASTER:N"', "spk286_debug_overlay.sv")
    require(overlay, 'text_at("SNAP:00"', "spk286_debug_overlay.sv")

    for required_test in (
        "scripts/test_debug_overlay.sh",
        "sim/spk286_integration/spk286_debug_overlay_tb.sv",
    ):
        if not (ROOT / required_test).is_file():
            raise SystemExit(f"project: missing required overlay test: {required_test}")

    rom = ROOT / "tests/firmware/pcat286_event_diag.rom"
    digest = hashlib.sha256(rom.read_bytes()).hexdigest()
    if rom.stat().st_size != 65536:
        raise SystemExit(f"diagnostic ROM: expected 65536 bytes, got {rom.stat().st_size}")

    print(
        "I4_PROJECT_CHECK_PASS "
        f"rom_size={rom.stat().st_size} rom_sha256={digest}"
    )


if __name__ == "__main__":
    main()
