#!/usr/bin/env bash
# Builds dump_tensor against the app's own DSP sources (not copies of them), so the
# tensor it prints is the one the app would hand BatDetect2.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/../../OpenBat"
out="${1:-$here/dump_tensor}"

swiftc -O -swift-version 5 -o "$out" \
  "$app/Classifier/SpectrogramRenderSpec.swift" \
  "$app/Classifier/ClassifierSpectrogramEngine.swift" \
  "$app/Classifier/BatDetect2SpectrogramRenderer.swift" \
  "$app/DSP/PolyphaseResampler.swift" \
  "$here/main.swift"

echo "built $out"
