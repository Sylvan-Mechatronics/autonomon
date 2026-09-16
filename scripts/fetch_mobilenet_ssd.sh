#!/usr/bin/env bash
# Fetch the MobileNet-SSD model used by the `follow-user` vision routine's
# `opencv-dnn` detector (OpenCvDnnDetector, run via cv2.dnn).
#
# This is a small Caffe MobileNet-SSD (Pascal VOC, person = class 15): a ~29 KB
# prototxt + a ~23 MB caffemodel. No Python deps beyond opencv-python-headless
# (the `vision-opencv` extra), which already provides cv2.dnn — unlike the YOLO
# path there is no onnxruntime and no model export step.
#
# Output (default ./models):
#   $MODEL_DIR/MobileNetSSD_deploy.prototxt
#   $MODEL_DIR/MobileNetSSD_deploy.caffemodel
# Point the routine at them with NOMON_VISION_MODEL_PATH (caffemodel) and
# NOMON_VISION_MODEL_CONFIG (prototxt), or the model_path / model_config params.
#
# Override the source URLs with NOMON_VISION_DNN_PROTO_URL / NOMON_VISION_DNN_MODEL_URL.
# Downloads are verified against pinned SHA-256 sums (review finding S-19); when
# you override a URL, also set NOMON_VISION_DNN_PROTO_SHA256 /
# NOMON_VISION_DNN_MODEL_SHA256 for the file you expect.
#
# Usage:
#   scripts/fetch_mobilenet_ssd.sh
set -euo pipefail

MODEL_DIR="${MODEL_DIR:-$(cd "$(dirname "$0")/.." && pwd)/models}"
PROTO_PATH="${PROTO_PATH:-$MODEL_DIR/MobileNetSSD_deploy.prototxt}"
MODEL_PATH="${MODEL_PATH:-$MODEL_DIR/MobileNetSSD_deploy.caffemodel}"

PROTO_URL="${NOMON_VISION_DNN_PROTO_URL:-https://raw.githubusercontent.com/djmv/MobilNet_SSD_opencv/master/MobileNetSSD_deploy.prototxt}"
MODEL_URL="${NOMON_VISION_DNN_MODEL_URL:-https://github.com/djmv/MobilNet_SSD_opencv/raw/master/MobileNetSSD_deploy.caffemodel}"

# Pinned digests of the upstream files (computed 2026-09-13).
PROTO_SHA256="${NOMON_VISION_DNN_PROTO_SHA256:-e781559c4f5beaec2a486ccd952af5b6fa408e9498761bf5f4fb80b4e9f0d25e}"
MODEL_SHA256="${NOMON_VISION_DNN_MODEL_SHA256:-761c86fbae3d8361dd454f7c740a964f62975ed32f4324b8b85994edec30f6af}"

verify_sha256() {
  local path="$1" expected="$2" actual
  actual="$(sha256sum "$path" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "Error: SHA-256 mismatch for $path" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    rm -f "$path"
    exit 1
  fi
}

mkdir -p "$MODEL_DIR"

if [ -f "$PROTO_PATH" ] && [ -f "$MODEL_PATH" ]; then
  echo "MobileNet-SSD already present: $PROTO_PATH, $MODEL_PATH"
  exit 0
fi

echo "Downloading MobileNet-SSD prototxt -> $PROTO_PATH"
curl -fSL "$PROTO_URL" -o "$PROTO_PATH"
verify_sha256 "$PROTO_PATH" "$PROTO_SHA256"

echo "Downloading MobileNet-SSD caffemodel (~23 MB) -> $MODEL_PATH"
curl -fSL "$MODEL_URL" -o "$MODEL_PATH"

verify_sha256 "$MODEL_PATH" "$MODEL_SHA256"

echo "Done. Set:"
echo "  NOMON_VISION_MODEL_PATH=$MODEL_PATH"
echo "  NOMON_VISION_MODEL_CONFIG=$PROTO_PATH"
