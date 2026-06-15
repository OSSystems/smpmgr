#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 O.S. Systems Software LTDA.
#
# Validate the OSSystems SMP stack against the freedom-zephyr firmware tests.
#
# This is the reusable, locally-runnable core of the sync-main-next pipeline.
# It builds a Python venv that OVERRIDES the smp / smpclient / smpmgr that
# freedom-zephyr's Nix devshell would otherwise provide (an old pinned smpmgr
# from common.nix) with:
#
#   smp       -> OSSystems/smp        @ ${SMP_REF}        (default main-ossystems-next)
#   smpclient -> intercreate/smpclient @ ${SMPCLIENT_REF} (default main)
#   smpmgr    -> the working tree at  ${SMPMGR_DIR}       (the candidate under test)
#
# Then it runs the two freedom-zephyr sample suites that exercise everything
# smpmgr needs:
#
#   * secure  -> python -m pytest (incl. tests/smpmgr_plugin, which imports the
#                plugins -> smp/smpclient) + the FOTA server simulator sequences
#   * forward -> twister Renode robot test that drives the smpmgr CLI through
#                the forward-tree protocol
#
# All freedom-zephyr tests reach the SMP stack either by importing the plugins
# under scripts/mcumgr (so the venv python must carry smp/smpclient) or by
# spawning the `smpmgr` CLI as a subprocess (so the venv's smpmgr must be first
# on PATH). Activating the venv (prepending its bin) satisfies both.
#
# No git-write side effects: safe to run locally.

set -euo pipefail

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Inputs (env vars with defaults) ----------------------------------------

SMPMGR_DIR="${SMPMGR_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

SMP_REPO="${SMP_REPO:-https://github.com/OSSystems/smp.git}"
SMP_REF="${SMP_REF:-main-ossystems-next}"

SMPCLIENT_REPO="${SMPCLIENT_REPO:-https://github.com/intercreate/smpclient.git}"
SMPCLIENT_REF="${SMPCLIENT_REF:-main}"

FREEDOM_ZEPHYR_REPO="${FREEDOM_ZEPHYR_REPO:-\
git@github.com:FreedomVeiculosEletricos/freedom-zephyr.git}"
FREEDOM_ZEPHYR_REF="${FREEDOM_ZEPHYR_REF:-main}"

# Optionally reuse existing local checkouts (fast local iteration).
SMP_DIR="${SMP_DIR:-}"
SMPCLIENT_DIR="${SMPCLIENT_DIR:-}"
FREEDOM_ZEPHYR_DIR="${FREEDOM_ZEPHYR_DIR:-}"

# If WORKDIR is unset we own a fresh temp dir and remove it on exit. If the
# caller passes WORKDIR (e.g. CI under the workspace), we keep it.
if [ -z "${WORKDIR:-}" ]; then
  WORKDIR="$(mktemp -d -t smpmgr-validate.XXXXXX)"
  KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
else
  mkdir -p "$WORKDIR"
  KEEP_WORKDIR="${KEEP_WORKDIR:-1}"
fi

cleanup() {
  [ "$KEEP_WORKDIR" != "1" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR" || true
}
trap cleanup EXIT

command -v nix >/dev/null 2>&1 \
  || die "nix not found on PATH; this script targets a Nix-enabled runner"

# --- Resolve source trees ----------------------------------------------------

clone_ref() {  # repo ref dest
  local repo="$1" ref="$2" dest="$3"
  log "Cloning ${repo} @ ${ref}"
  git clone --depth 1 --branch "$ref" "$repo" "$dest" 2>/dev/null \
    || git clone "$repo" "$dest"  # fall back for non-branch refs
  git -C "$dest" checkout "$ref" 2>/dev/null || true
}

if [ -z "$SMP_DIR" ]; then
  SMP_DIR="$WORKDIR/smp"
  clone_ref "$SMP_REPO" "$SMP_REF" "$SMP_DIR"
fi
if [ -z "$SMPCLIENT_DIR" ]; then
  SMPCLIENT_DIR="$WORKDIR/smpclient"
  clone_ref "$SMPCLIENT_REPO" "$SMPCLIENT_REF" "$SMPCLIENT_DIR"
fi
if [ -z "$FREEDOM_ZEPHYR_DIR" ]; then
  FREEDOM_ZEPHYR_DIR="$WORKDIR/freedom-zephyr"
  clone_ref "$FREEDOM_ZEPHYR_REPO" "$FREEDOM_ZEPHYR_REF" "$FREEDOM_ZEPHYR_DIR"
fi

log "Source trees:"
printf '  smp       = %s\n' "$SMP_DIR"
printf '  smpclient = %s\n' "$SMPCLIENT_DIR"
printf '  smpmgr    = %s\n' "$SMPMGR_DIR"
printf '  zephyr    = %s\n' "$FREEDOM_ZEPHYR_DIR"

# --- Run the validation inside the Nix devshell ------------------------------
#
# Everything from here runs inside `nix develop .#ci`. Exported vars are visible
# to the inner shell.

export SMP_DIR SMPCLIENT_DIR SMPMGR_DIR

cd "$FREEDOM_ZEPHYR_DIR"

nix develop .#ci --accept-flake-config --command bash -euo pipefail -s <<'INNER'
log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Fetch the Zephyr tree + HAL modules into deps/.
log "west update"
west config --global update.narrow true
west update

# 2. Build the override venv. --system-site-packages inherits the rich
#    zephyr.pythonEnv (cbor2, pydantic, anytree, httpx, pyyaml, colorama,
#    natsort, cryptography, requests, flask, pytest, pytest-asyncio, ...) so
#    we only add the SMP stack and the few runtime deps Nix lacks.
VENV="$PWD/.smpmgr-override-venv"
log "Creating override venv at ${VENV}"
rm -rf "$VENV"
python -m venv --system-site-packages "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --quiet --upgrade pip

log "Installing the SMP stack (override)"
# Plain (non-editable) wheel installs: editable installs (PEP 660) register a
# finder AFTER the standard path finder, so the Nix smp/smpclient/smpmgr on
# PYTHONPATH would still win. smp first, with deps (cbor2/crcmod/pydantic/
# eval-type-backport - no pin conflicts). smpclient and smpmgr go in with
# --no-deps so their '==' cross pins (smpmgr -> smpclient==X, smpclient ->
# smp==Y) can't drag a pinned package off PyPI on top of our checkouts.
pip install "$SMP_DIR"
pip install --no-deps "$SMPCLIENT_DIR"
pip install --no-deps "$SMPMGR_DIR"
# Third-party runtime deps of smpclient[all] + smpmgr that Nix's env may lack.
pip install "typer[all]" readchar bleak intelhex pyserial async-timeout

# The devshell exports a PYTHONPATH of Nix store site-packages that CPython
# searches BEFORE the venv's own site-packages. Prepend the venv site-packages
# so our smp/smpclient/smpmgr win, while every other Nix package stays
# importable behind them.
VENV_SITE="$(python -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
export PYTHONPATH="$VENV_SITE${PYTHONPATH:+:$PYTHONPATH}"

# 3. Assert the override actually took effect - this is the whole point. The
#    script MUST fail loudly if the stack still resolves to the Nix store,
#    otherwise we would silently validate the wrong smpmgr.
log "Verifying override"
which smpmgr
case "$(which smpmgr)" in
  "$VENV"/*) : ;;
  *) die "smpmgr CLI does not resolve into the override venv" ;;
esac
smpmgr --version
python - "$VENV_SITE" <<'PY' || die "override did not take effect: SMP stack resolves outside the venv (still Nix store?)"
import sys
import importlib.metadata as md
venv_site = sys.argv[1]
ok = True
for name in ("smp", "smpclient", "smpmgr"):
    mod = __import__(name)
    loc = getattr(mod, "__file__", "") or ""
    ver = md.version(name)
    inside = loc.startswith(venv_site)
    flag = "OK" if inside and "/nix/store/" not in loc else "WRONG-SOURCE"
    print(f"{name} {ver}: {loc} [{flag}]")
    ok = ok and inside and "/nix/store/" not in loc
sys.exit(0 if ok else 1)
PY

FAIL=0

# 4. secure suite: pytest (tests/ + samples/secure/simulator/tests) then the
#    FOTA server simulator sequences.
log "secure: pytest"
python -m pytest --junit-xml=pytest-results.xml || FAIL=1

log "secure: simulator sequences"
python samples/secure/scripts/create_test_file.py \
  --cert-dir cert --output-dir simulator_firmwares --build-sim || FAIL=1

SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
}
trap stop_server EXIT

eval "$(samples/secure/scripts/start_server.sh \
  --cert-dir cert --firmware-dir simulator_firmwares)"
python samples/secure/simulator/test_runner.py \
  samples/secure/simulator/test_sequences/*.yaml \
  --cert-dir cert --server "http://localhost:$SERVER_PORT" || FAIL=1
stop_server
SERVER_PID=""

# 5. forward suite: scoped twister Renode robot test (drives smpmgr CLI through
#    the forward-tree protocol).
log "forward: twister Renode robot test"
./deps/zephyr/scripts/twister -G --board-root . \
  -T samples/subsys/mgmt/mcumgr/forward \
  -p freenode --tag renode_tests \
  --clobber-output --inline-logs -v || FAIL=1

if [ "$FAIL" != "0" ]; then
  die "freedom-zephyr validation FAILED"
fi
log "freedom-zephyr validation PASSED"
INNER
