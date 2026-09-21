#!/usr/bin/env bash
#
# Runs OpenBat's own detection + classification over a library of recordings,
# by driving the harness in OpenBatTests on a simulator. This is the one part
# of the comparison that has to boot a simulator: the app's detector is UIKit
# code and its model is a Core ML bundle resource, so nothing here can run as a
# macOS command-line tool without becoming a re-implementation of what is being
# measured.
#
# It goes the long way round — build-for-testing, edit the generated
# .xctestrun, then test-without-building — because that plist is the only
# reliable way to put environment variables inside the test process.
# `xcodebuild test FOO=bar` sets a BUILD setting, which the running test never
# sees, and SIMCTL_CHILD_ only reaches a process launched through simctl.
#
# Usage:
#   ./run_app_arm.sh <input-dir> <results-dir> [limit]
#
# Environment:
#   SIM         simulator name (default: iPhone 17 Pro; it must exist at the
#               newest installed iOS, since the destination asks for OS:latest)
#   TENSORS     "0" to skip the per-pulse tensor dump the PyTorch arm needs
#   CONFIG      build configuration, default Release. Debug is what the app
#               normally runs, but this harness feeds audio far faster than
#               real time and the per-column peak scan is scalar Swift: at
#               -Onone the library takes hours, at -O minutes. The detections
#               are the same either way — this is not a timing measurement.
#               Release needs ENABLE_TESTABILITY=YES (below) or the test
#               target cannot `@testable import OpenBat`.
#   SKIP_CLASSIFY  "1" (default) renders each pulse's tensor without running
#               Core ML in-process. On a simulator that call returns zeros and
#               the score comes from the host, so it is pure cost. Set "0" when
#               running on a real device, where the in-app answer is the point.
#   AMPLITUDE   trigger threshold override (the app's own default is 0.5)
#   MIN_FREQ_KHZ  pitch gate override (the app's own default is 15)
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
project="$here/../.."

input="${1:?usage: run_app_arm.sh <input-dir> <results-dir> [limit]}"
results="${2:?usage: run_app_arm.sh <input-dir> <results-dir> [limit]}"
limit="${3:-}"
sim="${SIM:-iPhone 17 Pro}"
tensors="${TENSORS:-1}"
config="${CONFIG:-Release}"
skip_classify="${SKIP_CLASSIFY:-1}"
amplitude="${AMPLITUDE:-}"
min_freq="${MIN_FREQ_KHZ:-}"

mkdir -p "$results"
input="$(cd "$input" && pwd)"
results="$(cd "$results" && pwd)"

derived="$here/.derived"
mkdir -p "$derived"

echo "input   $input"
echo "results $results"
echo "sim     $sim ($config, skip_classify=$skip_classify)"

xcodebuild build-for-testing \
  -project "$project/OpenBat.xcodeproj" \
  -scheme OpenBat \
  -destination "platform=iOS Simulator,name=$sim" \
  -configuration "$config" \
  -derivedDataPath "$derived" \
  ENABLE_TESTABILITY=YES \
  -quiet

xctestrun="$(ls -t "$derived"/Build/Products/*.xctestrun | head -1)"
[ -n "$xctestrun" ] || { echo "no .xctestrun produced" >&2; exit 1; }

# The plist's shape differs between Xcode versions (TestPlans put each
# configuration under TestConfigurations); this finds the container that holds
# the OpenBatTests entry rather than assuming either layout.
/usr/bin/python3 - "$xctestrun" "$input" "$results" "$tensors" "$limit" "$amplitude" "$min_freq" "$skip_classify" <<'PY'
import plistlib, sys
path, input_dir, results_dir, tensors, limit, amplitude, min_freq, skip_classify = sys.argv[1:9]
with open(path, "rb") as handle:
    plist = plistlib.load(handle)

env = {
    "OPENBAT_EVAL_INPUT": input_dir,
    "OPENBAT_EVAL_OUTPUT": results_dir,
    "OPENBAT_EVAL_TENSORS": tensors,
    "OPENBAT_EVAL_SKIP_CLASSIFY": skip_classify,
}
if limit:
    env["OPENBAT_EVAL_LIMIT"] = limit
if amplitude:
    env["OPENBAT_EVAL_AMPLITUDE"] = amplitude
if min_freq:
    env["OPENBAT_EVAL_MIN_FREQ_KHZ"] = min_freq

def patch(target: dict) -> None:
    existing = target.get("EnvironmentVariables", {})
    existing.update(env)
    target["EnvironmentVariables"] = existing

patched = 0
for key, value in plist.items():
    if key == "TestConfigurations":
        for configuration in value:
            for target in configuration.get("TestTargets", []):
                if "OpenBatTests" in target.get("BlueprintName", ""):
                    patch(target)
                    patched += 1
    elif isinstance(value, dict) and "TestHostPath" in value and "OpenBatTests" in key:
        patch(value)
        patched += 1

if not patched:
    raise SystemExit(f"no OpenBatTests target found in {path}")
with open(path, "wb") as handle:
    plistlib.dump(plist, handle)
print(f"patched {patched} test target(s) in {path}")
PY

# `-parallel-testing-enabled NO` is not optional here. By default xcodebuild
# clones the simulator and runs the bundle on several clones at once, which for
# an ordinary test suite splits the work and for this one duplicates it: every
# clone walks the whole library and appends to the same app_arm.jsonl, so the
# machine does the work two or three times over and two writers race on one
# file. Observed 2026-09-21 as a run that slowed from 7 files/minute to 2 files
# in 25 minutes.
xcodebuild test-without-building \
  -xctestrun "$xctestrun" \
  -destination "platform=iOS Simulator,name=$sim" \
  -parallel-testing-enabled NO \
  -only-testing:OpenBatTests/BD2EvalHarnessTests

echo
echo "records: $results/app_arm.jsonl"
