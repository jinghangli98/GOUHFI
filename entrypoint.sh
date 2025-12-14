#!/bin/bash

# GOUHFI Wrapper Script
# Usage: ./entrypoint.sh <input_image_path> <output_file_path>
# Example: ./entrypoint.sh /path/to/image.nii.gz /path/to/segmentation.nii.gz
# Supports T1w, T2w, and TSE images in any naming format

set -e  # Exit on error

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <input_image_path> <output_file_path>"
    echo "Example: $0 /path/to/image.nii.gz /path/to/segmentation.nii.gz"
    exit 1
fi

INPUT_FILE="$1"
FINAL_SEGMENTATION="$2"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file does not exist: $INPUT_FILE"
    exit 1
fi

# Extract filename without path and extensions
FILENAME=$(basename "$INPUT_FILE")
BASENAME=$(basename "$INPUT_FILE" .nii.gz)
BASENAME=$(basename "$BASENAME" .nii)

# Try to extract BIDS-style subject and session (if present)
SUBJECT=$(echo "$FILENAME" | grep -oP 'sub-[^_]+' || echo "")
SESSION=$(echo "$FILENAME" | grep -oP 'ses-[^_]+' || echo "")

# If no BIDS-style IDs found, use the full basename as subject ID
if [ -z "$SUBJECT" ]; then
    SUBJECT="$BASENAME"
    echo "No BIDS-style subject ID found, using: $SUBJECT"
fi

# Detect modality from filename
MODALITY="t1"  # default
if echo "$FILENAME" | grep -qiE "(T2w|T2|TSE|t2w|t2|tse)"; then
    MODALITY="t2"
elif echo "$FILENAME" | grep -qiE "(T1w|T1|t1w|t1)"; then
    MODALITY="t1"
fi

# Extract output directory from output file path and create it
FINAL_OUTPUT_DIR=$(dirname "$FINAL_SEGMENTATION")
mkdir -p "$FINAL_OUTPUT_DIR"

echo "========================================"
echo "GOUHFI Segmentation Pipeline"
echo "========================================"
echo "Input:   $INPUT_FILE"
echo "Subject: $SUBJECT"
if [ -n "$SESSION" ]; then
    echo "Session: $SESSION"
fi
echo "Modality: $MODALITY"
echo "Output:  $FINAL_SEGMENTATION"
echo "========================================"

# Create temporary directory
TEMP_DIR=$(mktemp -d -t gouhfi_XXXXXX)
echo "Using temporary directory: $TEMP_DIR"

# Cleanup function - only cleanup on success
cleanup() {
    if [ $? -eq 0 ]; then
        echo "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    else
        echo "Error occurred. Temporary files preserved at: $TEMP_DIR"
        echo "You can inspect the files with:"
        echo "  find $TEMP_DIR -name '*.nii.gz'"
    fi
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

# Create properly named file for nnUNet
# Use a simplified naming scheme that works for all inputs
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
echo "Step 4/5: Finding and reorienting segmentation..."

# Find the segmentation file - search all possible locations
SEGMENTATION_FILE=""

# First, find all .nii.gz files in the output directory
echo "Searching for segmentation output..."
ALL_OUTPUT_FILES=$(find "$TEMP_OUTPUT" -name "*.nii.gz" -type f)

if [ -z "$ALL_OUTPUT_FILES" ]; then
    echo "Error: No .nii.gz files found in output directory!"
    echo "Output directory contents:"
    find "$TEMP_OUTPUT" -type f
    exit 1
fi

# Search in order of preference
for possible_dir in \
    "${TEMP_OUTPUT}/outputs_postpro_reo" \
    "${TEMP_OUTPUT}/outputs_postpro" \
    "${TEMP_OUTPUT}"; do
    
    if [ -d "$possible_dir" ]; then
        # Try exact match with session
        if [ -n "$SESSION" ]; then
            if [ -f "${possible_dir}/${SUBJECT}_${SESSION}.nii.gz" ]; then
                SEGMENTATION_FILE="${possible_dir}/${SUBJECT}_${SESSION}.nii.gz"
                break
            fi
        fi
        
        # Try exact match without session
        if [ -f "${possible_dir}/${SUBJECT}.nii.gz" ]; then
            SEGMENTATION_FILE="${possible_dir}/${SUBJECT}.nii.gz"
            break
        fi
        
        # Try to find any .nii.gz file in this directory
        found_file=$(find "$possible_dir" -maxdepth 1 -name "*.nii.gz" -type f | head -n 1)
        if [ -n "$found_file" ]; then
            SEGMENTATION_FILE="$found_file"
            break
        fi
    fi
done

# If still not found, just take the first .nii.gz file from anywhere in output
if [ -z "$SEGMENTATION_FILE" ] || [ ! -f "$SEGMENTATION_FILE" ]; then
    SEGMENTATION_FILE=$(echo "$ALL_OUTPUT_FILES" | head -n 1)
    if [ -n "$SEGMENTATION_FILE" ]; then
        echo "Warning: Using first available segmentation file: $SEGMENTATION_FILE"
    fi
fi

if [ -z "$SEGMENTATION_FILE" ] || [ ! -f "$SEGMENTATION_FILE" ]; then
    echo "Error: Could not find segmentation file!"
    echo "All .nii.gz files found:"
    echo "$ALL_OUTPUT_FILES"
    exit 1
fi

echo "Found segmentation file: $SEGMENTATION_FILE"

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
