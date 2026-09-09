#!/bin/bash
# =============================================================================
# gouhfi_pipeline — run the complete GOUHFI pipeline on ONE image
#
#   gouhfi_pipeline <input.nii[.gz]> <output_seg.nii.gz> [output_parc.nii.gz] [run_gouhfi options]
#
# Steps
#   1. Conform (LIA, 0-255) + ANTsPyNet brain extraction        (run_preprocessing)
#   2. Rename to the nnU-Net convention (<case>_0000.nii.gz)
#   3. GOUHFI inference + post-processing + FreeSurfer labels     (run_gouhfi --reorder_labels)
#        default      GOUHFI 2.0: subcortical segmentation + cortical parcellation (DKT)
#        --skip_parc  GOUHFI 2.0: segmentation only
#        --v1         original GOUHFI 1.0 model (segmentation only)
#   4. Reorient the label maps back onto the input image's voxel grid
#   5. Save <output_seg> (and <output_parc>; default: <output_seg> with a "_parc" suffix)
#
# Any other option (--cpu, --folds "0 1", --np 8, ...) is passed straight to run_gouhfi.
# The brain-extraction modality is guessed from the filename (T2/TSE -> t2, otherwise t1);
# set GOUHFI_MODALITY=t1|t2 to override.
#
# Convenience: if the first argument is a command (run_gouhfi, bash, python, ...) it is
# executed directly, e.g.   docker run --rm gouhfi run_gouhfi --help
# =============================================================================
set -euo pipefail

usage() {
    cat <<USAGE
Usage: gouhfi_pipeline <input.nii[.gz]> <output_seg.nii.gz> [output_parc.nii.gz] [run_gouhfi options]

Options forwarded to run_gouhfi (most useful ones):
  --v1          use the original GOUHFI 1.0 model (segmentation only)
  --skip_parc   GOUHFI 2.0 segmentation only, no cortical parcellation
  --cpu         run inference on CPU (much slower)
  --folds "0 1" use a subset of folds (faster, slightly less accurate)
  --np N        CPU processes for post-processing (default 4)

Environment:
  GOUHFI_MODALITY=t1|t2   force the brain-extraction modality (default: guessed from filename)

Examples:
  gouhfi_pipeline /input/sub-01_T1w.nii.gz /output/sub-01_seg.nii.gz
      -> /output/sub-01_seg.nii.gz  and  /output/sub-01_seg_parc.nii.gz
  gouhfi_pipeline /input/sub-01_T1w.nii.gz /output/sub-01_seg.nii.gz --v1
      -> /output/sub-01_seg.nii.gz  (GOUHFI 1.0 model)
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }
strip_ext() { local b="$1"; b="${b%.gz}"; b="${b%.nii}"; echo "$b"; }

# ---------------------------------------------------------------------------
# Pass-through: run an arbitrary command inside the container
# ---------------------------------------------------------------------------
if [ $# -ge 1 ] && [ ! -e "$1" ] && command -v "$1" >/dev/null 2>&1; then
    exec "$@"
fi
if [ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage; exit 0
fi
if [ $# -lt 2 ]; then
    usage; exit 1
fi

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
INPUT_FILE="$1"
OUTPUT_SEG="$2"
shift 2

OUTPUT_PARC=""
if [ $# -ge 1 ] && [[ "$1" != -* ]]; then
    OUTPUT_PARC="$1"
    shift
fi
GOUHFI_ARGS=("$@")

USE_V1=0
SKIP_PARC=0
for a in ${GOUHFI_ARGS[@]+"${GOUHFI_ARGS[@]}"}; do
    case "$a" in
        --v1)        USE_V1=1 ;;
        --skip_parc) SKIP_PARC=1 ;;
        --skip_seg)  die "--skip_seg is not supported here: the wrapper always starts from a raw image" ;;
        -i|--input_dir|-o|--output_dir|--reorder_labels)
                     die "$a is set by the wrapper and cannot be overridden" ;;
    esac
done

RUN_PARC=1
if [ "$USE_V1" -eq 1 ] || [ "$SKIP_PARC" -eq 1 ]; then
    RUN_PARC=0
fi
if [ "$RUN_PARC" -eq 1 ] && [ -z "$OUTPUT_PARC" ]; then
    OUTPUT_PARC="$(strip_ext "$OUTPUT_SEG")_parc.nii.gz"
fi
if [ "$RUN_PARC" -eq 0 ] && [ -n "$OUTPUT_PARC" ]; then
    echo "Warning: no cortical parcellation will be produced with --v1/--skip_parc; ignoring $OUTPUT_PARC"
    OUTPUT_PARC=""
fi

[ -f "$INPUT_FILE" ] || die "input file does not exist: $INPUT_FILE"
case "$INPUT_FILE" in
    *.nii|*.nii.gz) ;;
    *) echo "Warning: input does not end in .nii/.nii.gz — NIfTI is expected" ;;
esac

# ---------------------------------------------------------------------------
# Case identifier (BIDS sub-/ses- if present, otherwise the file basename)
# ---------------------------------------------------------------------------
FILENAME=$(basename "$INPUT_FILE")
BASENAME=$(strip_ext "$FILENAME")
SUBJECT=$(grep -oP 'sub-[^_.]+' <<<"$FILENAME" | head -n1 || true)
SESSION=$(grep -oP 'ses-[^_.]+' <<<"$FILENAME" | head -n1 || true)
if [ -n "$SUBJECT" ]; then
    CASE_ID="${SUBJECT}${SESSION:+_${SESSION}}"
else
    CASE_ID="$BASENAME"
fi

# ---------------------------------------------------------------------------
# Brain-extraction modality
# ---------------------------------------------------------------------------
MODALITY="${GOUHFI_MODALITY:-}"
if [ -z "$MODALITY" ]; then
    if grep -qiE 't2|tse' <<<"$FILENAME"; then MODALITY="t2"; else MODALITY="t1"; fi
fi
case "$MODALITY" in
    t1|t2) ;;
    *) die "GOUHFI_MODALITY must be t1 or t2 (got '$MODALITY')" ;;
esac

# ---------------------------------------------------------------------------
# ANTsPyNet weight cache: Keras silently falls back to /tmp/.keras (and tries to
# re-download) when KERAS_HOME is not writable, e.g. under Apptainer/Singularity or
# when running as a non-root user. Copy the pre-cached weights somewhere writable.
# ---------------------------------------------------------------------------
if [ -n "${KERAS_HOME:-}" ] && [ -d "$KERAS_HOME" ] && [ ! -w "$KERAS_HOME" ]; then
    WRITABLE_KERAS=$(mktemp -d -t keras_XXXXXX)
    cp -r "$KERAS_HOME"/. "$WRITABLE_KERAS"/
    export KERAS_HOME="$WRITABLE_KERAS"
    echo "KERAS_HOME was read-only; using a writable copy at $KERAS_HOME"
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
if [ "$USE_V1" -eq 1 ]; then
    PIPELINE_DESC="GOUHFI 1.0 (Dataset014) — subcortical segmentation"
elif [ "$RUN_PARC" -eq 1 ]; then
    PIPELINE_DESC="GOUHFI 2.0 — subcortical segmentation + cortical parcellation"
else
    PIPELINE_DESC="GOUHFI 2.0 — subcortical segmentation only"
fi

echo "========================================"
echo "GOUHFI Segmentation Pipeline"
echo "========================================"
echo "Pipeline: $PIPELINE_DESC"
echo "Input:    $INPUT_FILE"
echo "Case ID:  $CASE_ID"
echo "Modality: $MODALITY"
echo "Seg out:  $OUTPUT_SEG"
[ -n "$OUTPUT_PARC" ] && echo "Parc out: $OUTPUT_PARC"
[ ${#GOUHFI_ARGS[@]} -gt 0 ] && echo "Extra run_gouhfi args: ${GOUHFI_ARGS[*]}"
echo "========================================"

# ---------------------------------------------------------------------------
# Temporary workspace (kept on failure for inspection)
# ---------------------------------------------------------------------------
TEMP_DIR=$(mktemp -d -t gouhfi_XXXXXX)
echo "Using temporary directory: $TEMP_DIR"

cleanup() {
    local status=$?
    if [ "$status" -eq 0 ]; then
        echo "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    else
        echo "Error occurred (exit $status). Temporary files preserved at: $TEMP_DIR"
        echo "Inspect with:  find $TEMP_DIR -name '*.nii.gz'"
    fi
}
trap cleanup EXIT

TEMP_INPUT="$TEMP_DIR/input"
TEMP_PREP="$TEMP_DIR/prep"
TEMP_RENAMED="$TEMP_DIR/renamed"
TEMP_OUTPUT="$TEMP_DIR/output"
mkdir -p "$TEMP_INPUT" "$TEMP_PREP" "$TEMP_RENAMED" "$TEMP_OUTPUT"
cp "$INPUT_FILE" "$TEMP_INPUT/"

# ---------------------------------------------------------------------------
echo ""
echo "Step 1/5: Preprocessing (conforming + brain extraction, modality=$MODALITY)..."
run_preprocessing -i "$TEMP_INPUT" -o "$TEMP_PREP" --modality "$MODALITY"

# ---------------------------------------------------------------------------
echo ""
echo "Step 2/5: Renaming to the nnU-Net convention..."
mapfile -t PREP_FILES < <(find "$TEMP_PREP" -maxdepth 1 -type f \( -name '*.nii.gz' -o -name '*.nii' \))
if [ ${#PREP_FILES[@]} -ne 1 ]; then
    echo "Contents of $TEMP_PREP:"; ls -la "$TEMP_PREP" || true
    die "expected exactly one preprocessed image in $TEMP_PREP, found ${#PREP_FILES[@]}"
fi
PREP_FILE="${PREP_FILES[0]}"
RENAMED_FILE="$TEMP_RENAMED/${CASE_ID}_0000.nii.gz"
if [[ "$PREP_FILE" == *.gz ]]; then
    cp "$PREP_FILE" "$RENAMED_FILE"
else
    gzip -c "$PREP_FILE" > "$RENAMED_FILE"
fi
echo "  $PREP_FILE -> $RENAMED_FILE"

# ---------------------------------------------------------------------------
echo ""
echo "Step 3/5: Running GOUHFI ($PIPELINE_DESC)..."
run_gouhfi -i "$TEMP_RENAMED" -o "$TEMP_OUTPUT" --reorder_labels ${GOUHFI_ARGS[@]+"${GOUHFI_ARGS[@]}"}

# ---------------------------------------------------------------------------
echo ""
echo "Step 4/5: Reorienting results back onto the input image grid..."

# Print the result for one case in a run_gouhfi output folder (exact name first, else the
# single file present). Prints nothing if the folder does not exist.
find_result() {
    local d="$1"
    [ -d "$d" ] || return 0
    if [ -f "$d/${CASE_ID}.nii.gz" ]; then
        echo "$d/${CASE_ID}.nii.gz"
    else
        find "$d" -maxdepth 1 -type f -name '*.nii.gz' -print -quit
    fi
}

if [ "$USE_V1" -eq 1 ]; then
    SEG_RAW=$(find_result "$TEMP_OUTPUT/outputs_postpro_reo")
else
    SEG_RAW=$(find_result "$TEMP_OUTPUT/outputs_seg_postpro_reo")
fi
if [ -z "$SEG_RAW" ]; then
    echo "All .nii.gz files under $TEMP_OUTPUT:"; find "$TEMP_OUTPUT" -name '*.nii.gz' || true
    die "segmentation output not found"
fi
echo "  segmentation: $SEG_RAW"

PARC_RAW=""
if [ "$RUN_PARC" -eq 1 ]; then
    PARC_RAW=$(find_result "$TEMP_OUTPUT/outputs_parc_postpro_reo")
    if [ -z "$PARC_RAW" ]; then
        echo "All .nii.gz files under $TEMP_OUTPUT:"; find "$TEMP_OUTPUT" -name '*.nii.gz' || true
        die "parcellation output not found"
    fi
    echo "  parcellation: $PARC_RAW"
fi

# reorient_to_reference <label_map> <reference_image> <output>
# The conforming step only permutes/flips axes (no resampling), so the inverse is an exact
# orientation transform from the label map's axes (LIA) to the reference image's axes.
reorient_to_reference() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
import numpy as np
import nibabel as nib
from nibabel.orientations import io_orientation, ornt_transform, apply_orientation, inv_ornt_aff

seg_path, ref_path, out_path = sys.argv[1:4]
seg = nib.load(seg_path)
ref = nib.load(ref_path)

data = np.asanyarray(seg.dataobj)
if data.ndim == 4 and data.shape[3] == 1:
    data = data[..., 0]
xfm = ornt_transform(io_orientation(seg.affine), io_orientation(ref.affine))
data_ref = apply_orientation(data, xfm)

ref_shape = tuple(ref.shape[:3])
if tuple(data_ref.shape) != ref_shape:
    sys.exit(f"ERROR: reoriented label map shape {data_ref.shape} does not match the input image shape {ref_shape}")

# Geometry check: the label map's own affine, expressed in the reference axis order,
# should coincide with the reference affine (up to float round-off).
implied_aff = seg.affine @ inv_ornt_aff(xfm, data.shape)
max_diff = float(np.abs(implied_aff - ref.affine).max())
if max_diff > 1e-2:
    print(f"WARNING: label-map geometry differs from the input image (max affine difference {max_diff:.4f} mm); "
          "writing the labels on the input image grid anyway.")

out = nib.Nifti1Image(np.rint(data_ref).astype(np.int16), ref.affine)
out.header.set_zooms(ref.header.get_zooms()[:3])
out.header.set_xyzt_units(*ref.header.get_xyzt_units())
out.set_qform(ref.get_qform(), code=int(ref.header["qform_code"]))
out.set_sform(ref.get_sform(), code=int(ref.header["sform_code"]))
nib.save(out, out_path)

print(f"  {out_path}: shape {out.shape}, orientation {''.join(nib.aff2axcodes(out.affine))}, "
      f"{len(np.unique(data_ref)) - 1} non-zero labels")
PY
}

SEG_FINAL_TMP="$TEMP_DIR/seg_reoriented.nii.gz"
reorient_to_reference "$SEG_RAW" "$INPUT_FILE" "$SEG_FINAL_TMP"
if [ -n "$PARC_RAW" ]; then
    PARC_FINAL_TMP="$TEMP_DIR/parc_reoriented.nii.gz"
    reorient_to_reference "$PARC_RAW" "$INPUT_FILE" "$PARC_FINAL_TMP"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Step 5/5: Saving final results..."
mkdir -p "$(dirname "$OUTPUT_SEG")"
cp "$SEG_FINAL_TMP" "$OUTPUT_SEG"
if [ -n "$PARC_RAW" ]; then
    mkdir -p "$(dirname "$OUTPUT_PARC")"
    cp "$PARC_FINAL_TMP" "$OUTPUT_PARC"
fi

echo ""
echo "========================================"
echo "SUCCESS ($PIPELINE_DESC)"
echo "Segmentation:  $OUTPUT_SEG"
[ -n "$PARC_RAW" ] && echo "Parcellation:  $OUTPUT_PARC"
echo "========================================"
