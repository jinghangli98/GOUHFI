#!/bin/bash

# GOUHFI Wrapper Script
# Usage: ./entrypoint.sh <input_image_path> <output_file_path>
# Example: ./entrypoint.sh /path/to/sub-004_ses-01_T1w.nii.gz /path/to/sub-004_ses-01_T1w_seg.nii.gz
# Supports T1w, T2w, and TSE images

set -e  # Exit on error

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <input_image_path> <output_file_path>"
    echo "Example: $0 /ix1/.../sub-004_ses-01_T1w.nii.gz /ix1/.../sub-004_ses-01_T1w_seg.nii.gz"
    exit 1
fi

INPUT_FILE="$1"
FINAL_SEGMENTATION="$2"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file does not exist: $INPUT_FILE"
    exit 1
fi

# Extract subject and session from filename
FILENAME=$(basename "$INPUT_FILE")
# Extract sub-XXX
SUBJECT=$(echo "$FILENAME" | grep -oP 'sub-[^_]+')
# Extract ses-XX (if exists)
SESSION=$(echo "$FILENAME" | grep -oP 'ses-[^_]+' || echo "")

# Detect modality from filename
MODALITY="t1"  # default
if echo "$FILENAME" | grep -qiE "(T2w|TSE|t2w|tse)"; then
    MODALITY="t2"
elif echo "$FILENAME" | grep -qiE "(T1w|t1w)"; then
    MODALITY="t1"
fi

if [ -z "$SUBJECT" ]; then
    echo "Error: Could not extract subject ID from filename"
    exit 1
fi

# Extract output directory from output file path and create it
FINAL_OUTPUT_DIR=$(dirname "$FINAL_SEGMENTATION")
mkdir -p "$FINAL_OUTPUT_DIR"

echo "========================================"
echo "GOUHFI Segmentation Pipeline"
echo "========================================"
echo "Input:   $INPUT_FILE"
echo "Subject: $SUBJECT"
echo "Session: $SESSION"
echo "Output:  $FINAL_SEGMENTATION"
echo "========================================"

# Create temporary directory
TEMP_DIR=$(mktemp -d -t gouhfi_XXXXXX)
echo "Using temporary directory: $TEMP_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Create subdirectories
TEMP_INPUT="$TEMP_DIR/input"
TEMP_PREP="$TEMP_DIR/prep"
TEMP_RENAMED="$TEMP_DIR/renamed"
TEMP_OUTPUT="$TEMP_DIR/output"

mkdir -p "$TEMP_INPUT" "$TEMP_PREP" "$TEMP_RENAMED" "$TEMP_OUTPUT"

# Copy input file to temp
cp "$INPUT_FILE" "$TEMP_INPUT/"

echo ""
echo "Step 1/5: Preprocessing (conforming + brain extraction)..."
echo "Detected modality: $MODALITY"
run_preprocessing \
    -i "$TEMP_INPUT" \
    -o "$TEMP_PREP" \
    --modality "$MODALITY"

echo ""
echo "Step 2/5: Renaming to nnUNet format..."
# Find the preprocessed file (any .nii.gz file in prep directory)
PREP_FILE=$(find "$TEMP_PREP" -name "*.nii.gz" -type f | head -n 1)

if [ -z "$PREP_FILE" ]; then
    echo "Error: Could not find preprocessed file in $TEMP_PREP"
    echo "Files in prep directory:"
    ls -la "$TEMP_PREP" || echo "Directory does not exist"
    exit 1
fi

# Create properly named file
if [ -n "$SESSION" ]; then
    RENAMED_FILE="${TEMP_RENAMED}/${SUBJECT}_${SESSION}_0000.nii.gz"
else
    RENAMED_FILE="${TEMP_RENAMED}/${SUBJECT}_0000.nii.gz"
fi

cp "$PREP_FILE" "$RENAMED_FILE"

echo ""
echo "Step 3/5: Running GOUHFI segmentation..."
run_gouhfi \
    -i "$TEMP_RENAMED" \
    -o "$TEMP_OUTPUT" \
    --reorder_labels

echo ""
echo "Step 4/5: Reorienting segmentation back to original orientation..."

# Get segmentation file
if [ -n "$SESSION" ]; then
    SEGMENTATION_FILE="${TEMP_OUTPUT}/${SUBJECT}_${SESSION}.nii.gz"
else
    SEGMENTATION_FILE="${TEMP_OUTPUT}/${SUBJECT}.nii.gz"
fi

if [ ! -f "$SEGMENTATION_FILE" ]; then
    echo "Error: Segmentation file not found: $SEGMENTATION_FILE"
    exit 1
fi

# Reorient from LIA+ back to RAS+ and fix axis order to match original image
TEMP_REORIENTED="${TEMP_DIR}/reoriented.nii.gz"

# Use Python to swap axes and match original orientation
python3 << EOF
import nibabel as nib
import numpy as np

# Load segmentation and original
seg = nib.load('$SEGMENTATION_FILE')
orig = nib.load('$INPUT_FILE')

# Swap axes 1 and 2 to fix dimension order (320,352,448) -> (320,448,352)
seg_data = seg.get_fdata()
seg_data_swapped = np.swapaxes(seg_data, 1, 2)

seg_data_swapped = np.flip(seg_data_swapped, axis=2)
seg_data_swapped = np.flip(seg_data_swapped, axis=0)

# Create new image with original's affine and header to ensure proper alignment
seg_fixed = nib.Nifti1Image(seg_data_swapped.astype(np.int16), orig.affine, orig.header)

# Save
nib.save(seg_fixed, '$TEMP_REORIENTED')

print(f"Original shape: {orig.shape}")
print(f"Segmentation shape before: {seg.shape}")
print(f"Segmentation shape after: {seg_fixed.shape}")
EOF


echo ""
echo "Step 5/5: Saving final results..."
cp "$TEMP_REORIENTED" "$FINAL_SEGMENTATION"

echo ""
echo "========================================"
echo "SUCCESS!"
echo "Segmentation saved to:"
echo "$FINAL_SEGMENTATION"
echo ""
echo "Verifying orientation..."
if command -v mri_info &> /dev/null; then
    echo "Original: $(mri_info $INPUT_FILE | grep 'orientation' || echo 'unknown')"
    echo "Segmentation: $(mri_info $FINAL_SEGMENTATION | grep 'orientation' || echo 'unknown')"
fi
echo "========================================"
