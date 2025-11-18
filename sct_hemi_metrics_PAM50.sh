#!/usr/bin/env bash
# Compute spinal cord hemi volumes.
#
# MODE 1 (sagittal-style / long coverage):
#   - DICOM -> NIfTI
#   - Reorient to RPI
#   - Segment cord
#   - Vertebral labeling
#   - Register PAM50
#   - Warp PAM50 atlas, get L/R masks
#   - Compute per-vertebral-level left/right hemivol and CSA
#   - Merge into *_metrics_perlevel.csv
#
# MODE 2 (axial-style / tiny coverage):
#   - DICOM -> NIfTI
#   - Reorient to RPI
#   - Segment cord
#   - Skip vertebral labeling / PAM50
#   - Split segmentation down the midline in RPI space
#   - Output single CSV with total left/right volume in mm^3
#
# Usage:
#   ./sct_hemi_metrics_PAM50.sh "<path_to_dicom_folder>"
#
# Notes:
# - Works with Windows paths ("C:\...") or WSL paths (/mnt/c/...).
# - Run inside WSL with SCT env active (SCT_DIR must be set).
# - LEVELS controls vertebral range in sagittal mode.
# - Output folder = currentPWD/<SubjectID_sanitized>/

set -euo pipefail

#####################################
# USER SETTINGS
LEVELS="2:8"   # e.g., C2–C8 for per-level stats in sagittal mode
AXIAL_MIN_SLICES=5   # heuristic for deciding if we have "enough" SI coverage
#####################################

# ---- input path handling ----
RAW_INPUT="${1:-}"
if [ -z "$RAW_INPUT" ]; then
  echo "Usage: $0 <path_to_dicom_folder>"
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
  PARENT_DBG="$(dirname "$INPUT_DICOM_DIR")"
  ls -la "$PARENT_DBG" || true
  exit 1
fi

# ---- sanity checks ----
need_cmds=(dcm2niix sct_image sct_deepseg_sc sct_process_segmentation sct_maths python3 awk sed grep)
for cmd in "${need_cmds[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH."; exit 1; }
done
: "${SCT_DIR:?SCT_DIR not set. Activate the SCT environment so \$SCT_DIR exists.}"

# We'll lazy-check advanced SCT cmds (label_vertebrae, register_to_template, etc.)
have_label_vertebrae=1
command -v sct_label_vertebrae >/dev/null 2>&1 || have_label_vertebrae=0
have_register_to_template=1
command -v sct_register_to_template >/dev/null 2>&1 || have_register_to_template=0
have_apply_transfo=1
command -v sct_apply_transfo >/dev/null 2>&1 || have_apply_transfo=0
have_label_utils=1
command -v sct_label_utils >/dev/null 2>&1 || have_label_utils=0

# ---- derive subject id from the path (grandparent + parent) ----
GRANDPARENT="$(basename "$(dirname "$(dirname "$INPUT_DICOM_DIR")")")"
PARENT="$(basename "$(dirname "$INPUT_DICOM_DIR")")"
SUBJECT_ID="${GRANDPARENT}_${PARENT}"
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

# try expected filename first; else grab most recent *.nii*
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

# ---- Decide axial vs sagittal mode based on coverage ----
echo "==> QC: check segmentation coverage slices"

# We'll measure how many distinct non-empty axial slices exist in SEG.
# If it's < AXIAL_MIN_SLICES, we call it "axial mode" (tiny FOV). Otherwise "sagittal mode".
COVERAGE_SLICES=$(python3 - "$SEG" << 'PYCODE'
import sys, nibabel as nib, numpy as np
seg_path = sys.argv[1]
nii = nib.load(seg_path)
data = nii.get_fdata()
# data is RPI: X=R/L, Y=P/A, Z=I/S  (slice dim is Z)
nonempty = [(data[:,:,k] > 0).any() for k in range(data.shape[2])]
print(sum(nonempty))
PYCODE
)

if [ -z "$COVERAGE_SLICES" ]; then
  echo "WARNING: Could not measure coverage. Assuming very small coverage (axial mode)."
  COVERAGE_SLICES=0
else
  echo "Segmentation non-empty slices (heuristic): $COVERAGE_SLICES"
fi

MODE="sagittal"
if [ "$COVERAGE_SLICES" -lt "$AXIAL_MIN_SLICES" ]; then
  MODE="axial"
fi

echo "Selected processing mode: $MODE"

#####################################
# AXIAL MODE
#####################################
if [ "$MODE" = "axial" ]; then
  echo "==> Running axial fallback pipeline (no per-level metrics)."
  echo "NOTE: We will NOT run vertebral labeling or template registration."
  echo "      We will instead compute total left/right volumes over this stack."

  AXIAL_OUT="${SAFE_ID}_axial_hemi.csv"

  # We'll do all splitting/volume math in Python to avoid fragile awk on temp CSVs.
  python3 - "$IMG" "$SEG" "$AXIAL_OUT" "$SUBJECT_ID" << 'PYCODE'
import sys, csv
import nibabel as nib
import numpy as np

img_path   = sys.argv[1]  # anatomical T2_RPI (not strictly required except for reference)
seg_path   = sys.argv[2]  # segmentation mask
out_csv    = sys.argv[3]
subject_id = sys.argv[4]

nii = nib.load(seg_path)
seg_data = nii.get_fdata() > 0  # bool mask of cord
dx, dy, dz = nii.header.get_zooms()  # voxel size in mm (RPI space)

coords = np.argwhere(seg_data)
if coords.size == 0:
    # no segmentation?
    left_vox = right_vox = 0
    left_vol_mm3 = right_vol_mm3 = 0.0
    mid = np.nan
else:
    # x-axis index 0 = R/L dimension in RPI-reoriented image
    x_min = coords[:,0].min()
    x_max = coords[:,0].max()
    mid   = (x_min + x_max) // 2

    left_mask  = np.zeros_like(seg_data, dtype=bool)
    right_mask = np.zeros_like(seg_data, dtype=bool)

    # include mid voxel in "left" arbitrarily (consistent convention)
    left_mask[x_min:mid+1, :, :]   = seg_data[x_min:mid+1, :, :]
    right_mask[mid+1:x_max+1, :, :] = seg_data[mid+1:x_max+1, :, :]

    left_vox  = int(left_mask.sum())
    right_vox = int(right_mask.sum())

    voxel_mm3 = dx * dy * dz
    left_vol_mm3  = left_vox  * voxel_mm3
    right_vol_mm3 = right_vox * voxel_mm3

with open(out_csv, 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow([
        "subject",
        "left_voxels","right_voxels",
        "left_volume_mm3","right_volume_mm3",
        "voxel_volume_mm3",
        "split_mid_index_x",
        "note"
    ])
    voxel_mm3 = dx * dy * dz
    w.writerow([
        subject_id,
        left_vox, right_vox,
        left_vol_mm3, right_vol_mm3,
        voxel_mm3,
        mid,
        "Axial local stack; vertebral level not estimated"
    ])

print(f"[axial] wrote {out_csv}")
PYCODE

  echo "==> Done (axial mode)."
  echo "Outputs in: ${OUTDIR}"
  ls -1 "${AXIAL_OUT}" || true
  exit 0
fi

#####################################
# SAGITTAL MODE (full pipeline)
#####################################

# safety: check we actually have advanced SCT tools
if [ $have_label_vertebrae -eq 0 ] || [ $have_register_to_template -eq 0 ] || [ $have_apply_transfo -eq 0 ] || [ $have_label_utils -eq 0 ]; then
  echo "ERROR: Full sagittal pipeline requested, but required SCT tools are missing."
  echo "Need: sct_label_vertebrae, sct_register_to_template, sct_apply_transfo, sct_label_utils"
  exit 1
fi

# ---- Vertebral labeling (disc + body labels) ----
echo "==> Vertebral labeling"
sct_label_vertebrae -i "$IMG" -s "$SEG" -c t2

# Handle SCT output names
CAND1="$(basename "${IMG%.*.*}")_seg_labeled.nii.gz"   # e.g. *_T2_RPI_seg_labeled.nii.gz
CAND2="${SAFE_ID}_sc_labeled.nii.gz"                   # e.g. *_sc_labeled.nii.gz
if   [ -f "$CAND1" ]; then SEG_LABELED="$CAND1"
elif [ -f "$CAND2" ]; then SEG_LABELED="$CAND2"
else
  echo "ERROR: Vertebral labeled seg not found (looked for '$CAND1' and '$CAND2')."
  ls -la .
  exit 1
fi

DISC_LABELS="${SAFE_ID}_sc_labeled_discs.nii.gz"
[ -f "$DISC_LABELS" ] || { echo "ERROR: Disc labels not found: $DISC_LABELS"; exit 1; }

echo "Using vertebral level map: $SEG_LABELED"
echo "Using disc labels: $DISC_LABELS"

echo "==> Levels detected (FYI):"
sct_label_utils -i "$SEG_LABELED" -vert-body 0 || true

# ---- Register to PAM50 (template→anat) using disc labels ----
echo "==> Register to PAM50 (template→anat)"
sct_register_to_template -i "$IMG" -s "$SEG" -ldisc "$DISC_LABELS" -c t2

# ---- Warp ALL PAM50 atlas tracts into subject space ----
echo "==> Warp PAM50 atlas tracts into subject space"
PAM50_ATLAS_SRC="${SCT_DIR}/data/PAM50/atlas"
[ -d "$PAM50_ATLAS_SRC" ] || { echo "ERROR: PAM50 atlas not found at $PAM50_ATLAS_SRC. Run: sct_download_data -d pam50"; exit 1; }

ATLAS_DIR="label/atlas"
mkdir -p "$ATLAS_DIR"
cp -f "${PAM50_ATLAS_SRC}/info_label.txt" "${ATLAS_DIR}/" || true

echo "Warping atlas NIfTIs..."
shopt -s nullglob
n_warped=0
for f in "${PAM50_ATLAS_SRC}"/*.nii.gz; do
  bn="$(basename "$f")"
  sct_apply_transfo -i "$f" -d "$IMG" -w warp_template2anat.nii.gz -o "${ATLAS_DIR}/${bn}" >/dev/null
  n_warped=$((n_warped+1))
done
shopt -u nullglob
if [ "$n_warped" -eq 0 ]; then
  echo "ERROR: No atlas NIfTIs found to warp in ${PAM50_ATLAS_SRC}."
  echo "Verify PAM50 installation with: sct_download_data -d pam50"
  exit 1
fi
echo "Warped ${n_warped} atlas files into ${ATLAS_DIR}"

# ---- Build left/right atlas masks from info_label IDs ----
echo "==> Build left/right atlas masks"
INFO="${ATLAS_DIR}/info_label.txt"
[ -f "$INFO" ] || { echo "ERROR: ${INFO} not found."; exit 1; }

mapfile -t LEFT_IDS_ARR  < <(awk '
  BEGIN{ FS=","; IGNORECASE=1 }
  $0 !~ /^[[:space:]]*#/ && NF>=3 {
    id=$1; gsub(/[^0-9]/,"",id);
    name=$2; gsub(/^[ \t]+|[ \t\r]+$/,"",name);
    if (id != "" && name ~ /(^|[^a-z])(left)([^a-z]|$)/) print id
  }' "$INFO")

mapfile -t RIGHT_IDS_ARR < <(awk '
  BEGIN{ FS=","; IGNORECASE=1 }
  $0 !~ /^[[:space:]]*#/ && NF>=3 {
    id=$1; gsub(/[^0-9]/,"",id);
    name=$2; gsub(/^[ \t]+|[ \t\r]+$/,"",name);
    if (id != "" && name ~ /(^|[^a-z])(right)([^a-z]|$)/) print id
  }' "$INFO")

if [ "${#LEFT_IDS_ARR[@]}" -eq 0 ] || [ "${#RIGHT_IDS_ARR[@]}" -eq 0 ]; then
  echo "ERROR: Could not find Left/Right IDs in ${INFO}."
  echo "First 40 lines for reference:"; nl -ba "$INFO" | sed -n '1,40p'
  exit 1
fi

echo "Left IDs:  ${LEFT_IDS_ARR[*]}"
echo "Right IDs: ${RIGHT_IDS_ARR[*]}"

sum_files_into_mask () {
  local out_sum="$1"; shift
  local -a ids=( "$@" )
  local first_done=0
  rm -f "$out_sum"
  for id in "${ids[@]}"; do
    id="${id//[^0-9]/}"  # sanitize
    [ -z "$id" ] && continue
    idx=$(printf "%02d" "$id")
    f1="${ATLAS_DIR}/PAM50_atlas_${idx}.nii.gz"
    f2="${ATLAS_DIR}/PAM50_atlas_${id}.nii.gz"
    local f=""
    if   [ -f "$f1" ]; then f="$f1"
    elif [ -f "$f2" ]; then f="$f2"
    else
      echo "WARNING: Atlas file for ID ${id} not found (looked for ${f1} and ${f2}). Skipping."
      continue
    fi
    if [ "$first_done" -eq 0 ]; then
      cp "$f" "$out_sum"
      first_done=1
    else
      sct_maths -i "$out_sum" -add "$f" -o "$out_sum" >/dev/null
    fi
  done
  if [ "$first_done" -eq 0 ]; then
    echo "ERROR: No files were added to build ${out_sum}."
    return 1
  fi
}

tmp_left="atlas_left_labels_sum.nii.gz"
tmp_right="atlas_right_labels_sum.nii.gz"
sum_files_into_mask "$tmp_left"  "${LEFT_IDS_ARR[@]}"
sum_files_into_mask "$tmp_right" "${RIGHT_IDS_ARR[@]}"

# Binarize
sct_maths -i "$tmp_left"  -bin 0.5 -o atlas_left_mask_bin.nii.gz
sct_maths -i "$tmp_right" -bin 0.5 -o atlas_right_mask_bin.nii.gz

# Intersect with your segmentation to keep masks strictly inside cord
LEFT_MASK="${SAFE_ID}_hemi_left.nii.gz"
RIGHT_MASK="${SAFE_ID}_hemi_right.nii.gz"
sct_maths -i "$SEG" -mul atlas_left_mask_bin.nii.gz  -o "$LEFT_MASK"
sct_maths -i "$SEG" -mul atlas_right_mask_bin.nii.gz -o "$RIGHT_MASK"

echo "Created hemispheric masks: $LEFT_MASK , $RIGHT_MASK"

# ---- Output per-level metrics ----
OUT_L="${SAFE_ID}_left_hemivol_perlevel.csv"
OUT_R="${SAFE_ID}_right_hemivol_perlevel.csv"
OUT_CSA="${SAFE_ID}_csa_perlevel.csv"
METRICS_OUT="${SAFE_ID}_metrics_perlevel.csv"

LVL_ARGS=()
[ -n "$LEVELS" ] && LVL_ARGS=(-vert "$LEVELS")

LOC_FLAG=(-discfile "$DISC_LABELS")
if ! sct_process_segmentation -h 2>&1 | grep -q -- "-discfile"; then
  echo "NOTE: -discfile not available in your SCT; falling back to -vertfile (deprecated)."
  LOC_FLAG=(-vertfile "$SEG_LABELED")
fi

echo "==> Hemivolume per level (LEFT)"
sct_process_segmentation -i "$LEFT_MASK"  -perlevel 1 "${LOC_FLAG[@]}" "${LVL_ARGS[@]}" -o "$OUT_L"

echo "==> Hemivolume per level (RIGHT)"
sct_process_segmentation -i "$RIGHT_MASK" -perlevel 1 "${LOC_FLAG[@]}" "${LVL_ARGS[@]}" -o "$OUT_R"

echo "==> Whole-cord CSA per level"
sct_process_segmentation -i "$SEG" -perlevel 1 "${LOC_FLAG[@]}" "${LVL_ARGS[@]}" -o "$OUT_CSA"

# ---- Merge CSVs into one tidy table ----
echo "==> Merge metrics into ${METRICS_OUT}"
python3 - "${SUBJECT_ID}" "${OUT_L}" "${OUT_R}" "${OUT_CSA}" "${METRICS_OUT}" << 'PYCODE'
import sys, pandas as pd, numpy as np
subj, left_csv, right_csv, csa_csv, out_csv = sys.argv[1:6]
L = pd.read_csv(left_csv)
R = pd.read_csv(right_csv)
C = pd.read_csv(csa_csv)

def norm_level_cols(df):
    if 'level' in df.columns: return df
    for k in ('VertLevel','Label','label'):
        if k in df.columns:
            df = df.rename(columns={k:'level'})
            return df
    return df
L, R, C = map(norm_level_cols, (L,R,C))

def pick_vol_col(df):
    cols = [c for c in df.columns if 'volume' in c.lower()]
    if not cols:
        cols = [c for c in df.columns if c.lower().startswith('sum(')]
    if not cols:
        cols = [c for c in df.columns if 'area' in c.lower() and c.lower().startswith('mean')]
    return cols[0] if cols else None

volL = pick_vol_col(L) or L.columns[-1]
volR = pick_vol_col(R) or R.columns[-1]

L = L[['level', volL]].copy(); L.columns = ['level','value']; L['side']='L'
R = R[['level', volR]].copy(); R.columns = ['level','value']; R['side']='R'
H = pd.concat([L,R], ignore_index=True)

wide = H.pivot(index='level', columns='side', values='value').reset_index()
wide = wide.rename(columns={'L':'volume_mm3_left', 'R':'volume_mm3_right'})

def pick_csa_col(df):
    for c in df.columns:
        cl = c.lower()
        if 'csa' in cl:
            return c
    for c in df.columns:
        cl = c.lower()
        if 'area' in cl and cl.startswith('mean'):
            return c
    return None

csa_col = pick_csa_col(C)
if csa_col:
    C2 = C[['level', csa_col]].rename(columns={csa_col:'CSA_mm2'})
    wide = wide.merge(C2, on='level', how='left')

if {'volume_mm3_left','volume_mm3_right'}.issubset(wide.columns):
    wide['volume_mm3_total'] = wide['volume_mm3_left'].fillna(0) + wide['volume_mm3_right'].fillna(0)
    denom = wide['volume_mm3_total'].replace({0: np.nan})
    wide['asymmetry_index'] = (wide['volume_mm3_right'] - wide['volume_mm3_left']) / denom

wide.insert(0, 'subject', subj)
wide = wide.sort_values('level')
wide.to_csv(out_csv, index=False)
print(f"Wrote {out_csv}")
PYCODE

echo "==> Done (sagittal mode)."
echo "Outputs in: ${OUTDIR}"
ls -1 "${OUT_L}" "${OUT_R}" "${OUT_CSA}" "${METRICS_OUT}" || true
