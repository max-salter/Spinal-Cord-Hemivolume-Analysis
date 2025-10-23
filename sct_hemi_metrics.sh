#!/usr/bin/env bash
# Compute left/right hemivolumes per vertebral level from a sagittal T2 DICOM folder.
# Outputs tidy CSV with subject, level, volume_mm3_left/right/total, asymmetry_index, CSA_mm2.
#
# Usage:
#   ./sct_hemi_metrics.sh "<path_to_SAG_T2_folder>"
#
# Notes:
# - Path may be Windows-style (C:\...\SAG_T2_2) or WSL (/mnt/c/...).
# - Run inside WSL with SCT env active.
# - Vertebral levels range defaults to C2–C8; edit LEVELS below to change.
# - Creates an output folder named after a sanitized subject ID under your current directory.

set -euo pipefail

#####################################
# USER SETTINGS
LEVELS="2:8"   # e.g., C2–C8; set to "" for all detected levels
#####################################

# ---- input path handling ----
RAW_INPUT="${1:-}"
if [ -z "$RAW_INPUT" ]; then
  echo "Usage: $0 <path_to_SAG_T2_folder>"
  exit 1
fi

# Normalize to WSL path
if [[ "$RAW_INPUT" == /mnt/* ]]; then
  INPUT_DICOM_DIR="$RAW_INPUT"
else
  INPUT_DICOM_DIR="$(wslpath -a "$RAW_INPUT")"
fi

if [ ! -d "$INPUT_DICOM_DIR" ]; then
  echo "ERROR: DICOM dir not found: $INPUT_DICOM_DIR"
  echo "Parent listing (to help spot exact name):"
  PARENT="$(dirname "$INPUT_DICOM_DIR")"
  ls -la "$PARENT" || true
  exit 1
fi

# ---- sanity checks ----
need_cmds=(dcm2niix sct_image sct_deepseg_sc sct_label_vertebrae sct_process_segmentation python3)
for cmd in "${need_cmds[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH."; exit 1; }
done

# ---- derive subject id from the path (grandparent + parent) ----
# Example path .../Subject_1/Injury_F_53/CSpine_Routine - 3869894001/SAG_T2_2
GRANDPARENT="$(basename "$(dirname "$(dirname "$INPUT_DICOM_DIR")")")"   # e.g., Injury_F_53
PARENT="$(basename "$(dirname "$INPUT_DICOM_DIR")")"                     # e.g., CSpine_Routine - 3869894001
SUBJECT_ID="${GRANDPARENT}_${PARENT}"
# Sanitize for filesystem (spaces and odd chars -> underscores)
SAFE_ID="$(echo "$SUBJECT_ID" | sed -E 's/[^A-Za-z0-9._-]+/_/g')"

echo "Detected subject ID: ${SUBJECT_ID}"
echo "Sanitized ID for filenames: ${SAFE_ID}"

# ---- workspace ----
OUTDIR="${PWD}/${SAFE_ID}"
mkdir -p "${OUTDIR}/nifti"
cd "${OUTDIR}"

# ---- DICOM -> NIfTI ----
echo "==> DICOM → NIfTI"
dcm2niix -o "./nifti" -f "${SAFE_ID}_T2" -z y "$INPUT_DICOM_DIR"

# Expect this filename; if not found, pick most recent NIfTI in ./nifti
T2_IN="./nifti/${SAFE_ID}_T2.nii.gz"
if [ ! -f "$T2_IN" ]; then
  echo "NIfTI not at expected path: $T2_IN ; trying auto-detect…"
  T2_IN="$(ls -1t ./nifti/*.nii* 2>/dev/null | head -n1 || true)"
fi
[ -f "$T2_IN" ] || { echo "ERROR: NIfTI not created (looked in ./nifti)."; ls -la ./nifti || true; exit 1; }

# ---- Reorient to RPI ----
echo "==> Reorient to RPI"
IMG="${SAFE_ID}_T2_RPI.nii.gz"
sct_image -i "$T2_IN" -setorient RPI -o "$IMG"

# ---- Segment spinal cord ----
echo "==> Segment spinal cord"
SEG="${SAFE_ID}_sc.nii.gz"
sct_deepseg_sc -i "$IMG" -c t2 -o "$SEG"

# ---- Vertebral labeling ----
echo "==> Vertebral labeling"
sct_label_vertebrae -i "$IMG" -s "$SEG" -c t2

# Accept either possible filename that SCT may write:
CAND1="$(basename "${IMG%.*.*}")_seg_labeled.nii.gz"   # e.g., *_T2_RPI_seg_labeled.nii.gz
CAND2="${SAFE_ID}_sc_labeled.nii.gz"                   # e.g., *_sc_labeled.nii.gz

if   [ -f "$CAND1" ]; then SEG_LABELED="$CAND1"
elif [ -f "$CAND2" ]; then SEG_LABELED="$CAND2"
else
  echo "ERROR: Vertebral labeled seg not found (looked for '$CAND1' and '$CAND2')."
  ls -la .
  exit 1
fi
echo "Using vertebral level map: $SEG_LABELED"

echo "==> Levels detected (for info, not a failure if empty below):"
sct_label_utils -i "$SEG_LABELED" -vert-body 0 || true

# ---- Build Left/Right hemicord masks from segmentation midline (per slice) ----
echo "==> Create left/right hemicord masks from segmentation midline (per slice)"

# Define outputs *before* running Python (so set -u never complains)
LEFT_MASK="${SAFE_ID}_hemi_left.nii.gz"
RIGHT_MASK="${SAFE_ID}_hemi_right.nii.gz"

python3 - "${IMG}" "${SEG}" "${LEFT_MASK}" "${RIGHT_MASK}" << 'PYCODE'
import sys, os, numpy as np
import nibabel as nib

# argv: 0=script, 1=img_path, 2=seg_path, 3=left_out, 4=right_out
if len(sys.argv) < 5:
    print("ERROR: expected 4 arguments: IMG SEG LEFT_OUT RIGHT_OUT", file=sys.stderr)
    sys.exit(2)

img_path  = os.path.abspath(sys.argv[1])  # not used here
seg_path  = os.path.abspath(sys.argv[2])
left_out  = os.path.abspath(sys.argv[3])
right_out = os.path.abspath(sys.argv[4])

seg = nib.load(seg_path)
seg_data = (seg.get_fdata() > 0).astype(np.uint8)

nx, ny, nz = seg_data.shape
left  = np.zeros_like(seg_data, dtype=np.uint8)
right = np.zeros_like(seg_data, dtype=np.uint8)

# Split per slice using x center-of-mass of the segmentation (RPI)
for k in range(nz):
    sl = seg_data[:, :, k]
    if sl.any():
        xs = np.where(sl > 0)[0]
        xmid = int(np.round(xs.mean()))
        # anatomical right = x < mid; left = x >= mid
        right[:xmid, :, k] = sl[:xmid, :]
        left[xmid:,  :, k] = sl[xmid:, :]

nib.save(nib.Nifti1Image(left,  seg.affine, seg.header), left_out)
nib.save(nib.Nifti1Image(right, seg.affine, seg.header), right_out)
print(f"Wrote {left_out} and {right_out}")
PYCODE

# sanity checks
[ -f "$LEFT_MASK" ]  || { echo "ERROR: did not create $LEFT_MASK";  exit 1; }
[ -f "$RIGHT_MASK" ] || { echo "ERROR: did not create $RIGHT_MASK"; exit 1; }

# ---- Extract metrics per level ----
OUT_L="${SAFE_ID}_left_hemivol_perlevel.csv"
OUT_R="${SAFE_ID}_right_hemivol_perlevel.csv"
OUT_CSA="${SAFE_ID}_csa_perlevel.csv"
METRICS_OUT="${SAFE_ID}_metrics_perlevel.csv"

# Build optional level args
LVL_ARGS=()
if [ -n "$LEVELS" ]; then
  LVL_ARGS=(-vert "$LEVELS")
fi

echo "==> Hemivolume per level (LEFT)"
sct_process_segmentation -i "$LEFT_MASK"  -perlevel 1 -o "$OUT_L"  -vertfile "$SEG_LABELED" "${LVL_ARGS[@]}"

echo "==> Hemivolume per level (RIGHT)"
sct_process_segmentation -i "$RIGHT_MASK" -perlevel 1 -o "$OUT_R"  -vertfile "$SEG_LABELED" "${LVL_ARGS[@]}"

echo "==> Whole-cord CSA per level"
sct_process_segmentation -i "$SEG"       -perlevel 1 -o "$OUT_CSA" -vertfile "$SEG_LABELED" "${LVL_ARGS[@]}"

# ---- Merge CSVs into one tidy table ----
python3 - "${SUBJECT_ID}" "${OUT_L}" "${OUT_R}" "${OUT_CSA}" "${METRICS_OUT}" << 'PYCODE'
import sys, pandas as pd
import numpy as np

subj, left_csv, right_csv, csa_csv, out_csv = sys.argv[1:6]

# Load
L = pd.read_csv(left_csv)
R = pd.read_csv(right_csv)
C = pd.read_csv(csa_csv)

# ---- Normalize column names ----
for df in (L, R, C):
    if 'label' in df.columns:
        df.rename(columns={'label':'level'}, inplace=True)
    if 'VertLevel' in df.columns:
        df.rename(columns={'VertLevel':'level'}, inplace=True)

# ---- Identify volume columns ----
def pick_vol_col(df):
    for c in df.columns:
        cl = c.lower()
        if 'volume' in cl:
            return c
    for c in df.columns:
        if 'nb_vox' in c.lower() or 'sum' in c.lower():
            return c
    return df.columns[-1]

volL = pick_vol_col(L)
volR = pick_vol_col(R)

# ---- Stack L/R ----
L2 = L[['level', volL]].rename(columns={volL:'volume_mm3_left'})
R2 = R[['level', volR]].rename(columns={volR:'volume_mm3_right'})
M = pd.merge(L2, R2, on='level', how='outer')

# ---- Add CSA ----
csa_col = next((c for c in C.columns if 'csa' in c.lower() or 'area' in c.lower()), None)
if csa_col:
    C2 = C[['level', csa_col]].rename(columns={csa_col:'CSA_mm2'})
    M = M.merge(C2, on='level', how='left')

# ---- Derived metrics ----
M['volume_mm3_total'] = M['volume_mm3_left'] + M['volume_mm3_right']
M['asymmetry_index'] = (M['volume_mm3_right'] - M['volume_mm3_left']) / M['volume_mm3_total'].replace(0, np.nan)

# ---- Clean up ----
M.insert(0, 'subject', subj)
M = M.sort_values('level', key=lambda x: pd.to_numeric(x, errors='coerce'))
M = M[['subject','level','CSA_mm2','volume_mm3_left','volume_mm3_right','volume_mm3_total','asymmetry_index']]

# Round numeric values to 3 decimals
for c in M.select_dtypes(include='number').columns:
    M[c] = M[c].round(3)

M.to_csv(out_csv, index=False)
print(f"Wrote clean summary table → {out_csv}")
print(M)
PYCODE

echo "==> Done."
echo "Outputs in: ${OUTDIR}"
ls -1 "${OUT_L}" "${OUT_R}" "${OUT_CSA}" "${METRICS_OUT}" || true
