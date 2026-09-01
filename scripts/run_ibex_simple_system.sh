#!/usr/bin/env bash
# Run the lowRISC Ibex simple_system hello_test under xezim.
#
# This demonstrates xezim compiling and simulating a real-world RISC-V CPU
# core (lowRISC Ibex) with its simple_system testbench.  The script uses
# FuseSoC to resolve the Ibex RTL file list, then invokes xezim on it.
#
# Prerequisites:
#   - xezim built at $XEZIM (default: repo-root/target/release/xezim)
#   - Ibex checkout at $IBEX_DIR
#   - FuseSoC installed (uv tool install fusesoc)
#   - RISC-V toolchain + srecord installed (for building firmware)
#   - Python pyyaml installed (for util/ibex_config.py)
#
# Usage:
#   ./scripts/run_ibex_simple_system.sh
#
# Environment:
#   XEZIM       path to xezim binary (default: repo-root/target/release/xezim)
#   IBEX_DIR    path to ibex checkout (required)
#   IBEX_CONFIG ibex configuration name (default: small)
#   MAX_TIME    simulation time cap in ns (default: 200000)
#   FIRMWARE    path to .vmem firmware file (default: auto-built hello_test)
#
# Exit codes:
#   0  simulation ran and expected output was found
#   1  setup or compilation error
#   2  simulation ran but expected output was NOT found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

XEZIM="${XEZIM:-$REPO_ROOT/target/release/xezim}"
IBEX_DIR="${IBEX_DIR:?IBEX_DIR must be set to the ibex checkout path}"
IBEX_CONFIG="${IBEX_CONFIG:-small}"
MAX_TIME="${MAX_TIME:-200000}"

# ── Resolve firmware ────────────────────────────────────────────────
if [[ -z "${FIRMWARE:-}" ]]; then
    FIRMWARE="$IBEX_DIR/examples/sw/simple_system/hello_test/hello_test.vmem"
fi
if [[ ! -f "$FIRMWARE" ]]; then
    echo "error: firmware not found at $FIRMWARE" >&2
    echo "       build it with: make -C $IBEX_DIR/examples/sw/simple_system/hello_test" >&2
    exit 1
fi

# ── Generate the FuseSoC file list ──────────────────────────────────
BUILD_DIR="$IBEX_DIR/build/xezim"
echo "==> Generating FuseSoC file list ($IBEX_CONFIG config)…"

# Read the FuseSoC parameters for the chosen configuration.
FUSESOC_OPTS=$(cd "$IBEX_DIR" && python3 util/ibex_config.py "$IBEX_CONFIG" fusesoc_opts)

# Use --tool=vcs so FuseSoC generates a VCS-style .vc filelist (which
# xezim's -f parser understands: +incdir+, +define+, -y, file paths).
# --setup only generates the file list; --build would try to invoke VCS.
( cd "$IBEX_DIR" && \
  fusesoc --cores-root=. run --target=sim --tool=vcs \
    --setup --build-dir="$BUILD_DIR" \
    lowrisc:ibex:ibex_simple_system \
    $FUSESOC_OPTS \
    --SRAMInitFile="$(cd "$(dirname "$FIRMWARE")" && pwd)/$(basename "$FIRMWARE")" \
) || { echo "error: FuseSoC setup failed" >&2; exit 1; }

# Locate the generated .vc file list.
VC_FILE=$(find "$BUILD_DIR" -name '*.vc' -print -quit || true)
if [[ -z "$VC_FILE" || ! -f "$VC_FILE" ]]; then
    echo "error: no .vc filelist found under $BUILD_DIR" >&2
    exit 1
fi
echo "    file list: $VC_FILE"

# ── Create a wrapper module ─────────────────────────────────────────
# xezim does not support -pvalue parameter overrides, so we create a
# thin wrapper that instantiates ibex_simple_system with the firmware
# path as an explicit parameter override.  The VERILATOR ifdef is NOT
# set, so ibex_simple_system generates its own clock and reset — the
# IO_CLK/IO_RST_N ports are tied off and ignored.
WRAPPER="$BUILD_DIR/ibex_xezim_top.sv"
VMEM_ABS="$(cd "$(dirname "$FIRMWARE")" && pwd)/$(basename "$FIRMWARE")"
cat > "$WRAPPER" << EOF
\`timescale 1ns/1ps

// xezim wrapper for ibex simple_system — sets SRAMInitFile parameter
// (a vlogparam that FuseSoC would pass via -pvalue, which xezim does
// not support).  All other parameters use RTL defaults that match the
// $IBEX_CONFIG configuration's vlogparam values.
module ibex_xezim_top;
  ibex_simple_system #(
    .SRAMInitFile("$VMEM_ABS")
  ) u_dut (
    .IO_CLK(1'b0),
    .IO_RST_N(1'b0)
  );
endmodule
EOF
echo "    wrapper:  $WRAPPER"

# ── Run xezim ───────────────────────────────────────────────────────
echo "==> Running xezim (max-time ${MAX_TIME}ns)…"

WORK_DIR="$BUILD_DIR/run"
mkdir -p "$WORK_DIR"

# Run from WORK_DIR so ibex_simple_system.log lands in a known place.
( cd "$WORK_DIR" && \
  "$XEZIM" --simulate \
    -f "$VC_FILE" \
    "$WRAPPER" \
    -s ibex_xezim_top \
    --max-time "$MAX_TIME" \
    --no-cache \
    2>&1 \
) | tee "$WORK_DIR/xezim_stdout.log" || true

# ── Verify output ───────────────────────────────────────────────────
LOG_FILE="$WORK_DIR/ibex_simple_system.log"
echo "==> Checking output…"

if [[ ! -f "$LOG_FILE" ]]; then
    echo "error: $LOG_FILE was not produced" >&2
    exit 2
fi

if grep -q "Hello simple system" "$LOG_FILE"; then
    echo "✓ PASS: 'Hello simple system' found in simulation log"
    echo
    echo "--- ibex_simple_system.log ---"
    cat "$LOG_FILE"
    echo "-------------------------------"
    exit 0
else
    echo "✗ FAIL: 'Hello simple system' NOT found in simulation log" >&2
    echo
    echo "--- ibex_simple_system.log ---"
    cat "$LOG_FILE" 2>/dev/null || echo "(empty or missing)"
    echo "-------------------------------"
    exit 2
fi
