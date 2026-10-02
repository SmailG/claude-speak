#!/bin/bash
# Platform checks, sourced by setup.sh (and by tests/shell.test.sh with stubbed commands).

MIN_MACOS_MAJOR=14   # oldest macOS that MLX ships wheels for (macosx_14_0_arm64)

# Prints why this machine can't run voice-conversation; prints nothing when it can.
platform_problem() {
  local version major
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "voice-conversation needs macOS on Apple Silicon; this is $(uname -s)"
    return
  fi
  # Under Rosetta, uname -m says x86_64 even on Apple Silicon; hw.optional.arm64 tells the truth.
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]; then
    echo "voice-conversation needs an Apple Silicon Mac (M1 or later); MLX does not run on Intel Macs"
    return
  fi
  version=$(sw_vers -productVersion 2>/dev/null)
  major="${version%%.*}"
  if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt "$MIN_MACOS_MAJOR" ]; then
    echo "voice-conversation needs macOS $MIN_MACOS_MAJOR Sonoma or newer; this is macOS ${version:-unknown}"
  fi
}

# True when this shell runs under Rosetta on an Apple Silicon Mac.
is_translated() {
  [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]
}
