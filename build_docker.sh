#!/bin/bash
# Build the self-contained GOUHFI pipeline image (code + model weights + ANTsPyNet cache).
#
#   ./build_docker.sh [image_name] [tag]        default: gouhfi:2.0.1 (also tagged :latest)
#
# Extra arguments after the tag are passed to `docker build`, e.g.
#   ./build_docker.sh gouhfi 2.0.1 --build-arg PRECACHE_ANTSPYNET=0
set -euo pipefail
cd "$(dirname "$0")"

IMAGE_NAME="${1:-gouhfi}"
IMAGE_TAG="${2:-2.0.1}"
shift $(( $# >= 2 ? 2 : $# ))

# --- model weights must be unpacked under trained_model/ (see DOCKER.md) ---
missing=0
for d in Dataset020_gouhfi_2p0n2 Dataset024_gouhfi_parc; do
    if ! ls "trained_model/$d"/*/plans.json >/dev/null 2>&1; then
        echo "ERROR: GOUHFI 2.0 weights missing: trained_model/$d"
        missing=1
    fi
done
if [ "$missing" = 1 ]; then
    echo "Download and unzip them first (Zenodo 17920473 or https://huggingface.co/mafortin/GOUHFI2p0)."
    exit 1
fi
if ! ls trained_model/Dataset014_gouhfi/*/plans.json >/dev/null 2>&1; then
    echo "NOTE: trained_model/Dataset014_gouhfi (GOUHFI 1.0) not found; the image will not support --v1."
fi

# --- docker, with sudo when the current user cannot reach the daemon ---
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    echo "docker daemon not reachable as $(id -un); using sudo"
    DOCKER=(sudo docker)
fi

echo "Building ${IMAGE_NAME}:${IMAGE_TAG} from Dockerfile.pipeline (BuildKit)"
echo "Weights included: $(ls -d trained_model/Dataset*/ | xargs -n1 basename | tr '\n' ' ')"
echo ""

DOCKER_BUILDKIT=1 "${DOCKER[@]}" build \
    -f Dockerfile.pipeline \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -t "${IMAGE_NAME}:latest" \
    "$@" .

echo ""
echo "Build complete: ${IMAGE_NAME}:${IMAGE_TAG}  (size: $("${DOCKER[@]}" images --format '{{.Size}}' "${IMAGE_NAME}:${IMAGE_TAG}"))"
echo ""
echo "Smoke test:"
echo "  ${DOCKER[*]} run --rm ${IMAGE_NAME}:${IMAGE_TAG} run_gouhfi --help"
echo ""
echo "Run the full pipeline on one image (writes <name>.nii.gz and <name>_parc.nii.gz):"
echo "  ${DOCKER[*]} run --rm --gpus all --shm-size=16g -e HOST_UID=\$(id -u) -e HOST_GID=\$(id -g) \\"
echo "      -v /path/to/input:/input -v /path/to/output:/output \\"
echo "      ${IMAGE_NAME}:${IMAGE_TAG} /input/image.nii.gz /output/image_seg.nii.gz"
