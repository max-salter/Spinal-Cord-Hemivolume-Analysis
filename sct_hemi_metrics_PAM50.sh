#!/usr/bin/env bash
# Compute left/right hemivolumes per vertebral level from a sagittal T2 DICOM folder, using PAM50 atlas L/R masks.
# Outputs CSVs: *_left_hemivol_perlevel.csv, *_right_hemivol_perlevel.csv, *_csa_perlevel.csv, *_metrics_perlevel.csv
#
# Usage:
#   ./sct_hemi_metrics_PAM50.sh "<path_to_SAG_T2_folder>"
#
# Notes:
# - Path may be Windows-style (C:\...\SAG_T2_2) or WSL (/mnt/c/...).
# - Run inside WSL with SCT env active (e.g., `conda activate sct`).
# - Vertebral range defaults to C2–C8 (change LEVELS below).
# - Creates an output folder named after a sanitized subject ID under the current directory.

set -euo pipefail

#####################################
# USER SETTINGS
LEVELS="2:8"   # e.g., C2–C8; empty string "" = all detected levels
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
need_cmds=(dcm2niix sct_image sct_deepseg_sc sct_label_vertebrae sct_process_segmentation sct_register_to_template sct_apply_transfo sct_maths sct_label_utils python3 awk sed grep)
for cmd in "${need_cmds[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH."; exit 1; }
done
: "${SCT_DIR:?SCT_DIR not set. Activate the SCT environment so \$SCT_DIR exists.}"

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

# ---- Vertebral labeling (disc + body labels) ----
echo "==> Vertebral labeling"
sct_label_vertebrae -i "$IMG" -s "$SEG" -c t2

# Handle SCT output file names (version dependent)
CAND1="$(basename "${IMG%.*.*}")_seg_labeled.nii.gz"   # *_T2_RPI_seg_labeled.nii.gz
CAND2="${SAFE_ID}_sc_labeled.nii.gz"                   # *_sc_labeled.nii.gz
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

# ---- Build left/right atlas masks from info_label IDs (sanitize IDs) ----
echo "==> Build left/right atlas masks"
INFO="${ATLAS_DIR}/info_label.txt"
[ -f "$INFO" ] || { echo "ERROR: ${INFO} not found."; exit 1; }

# Extract IDs from "ID, name, file" CSV; ignore comments; keep digits only in ID.
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

# Helper: add list of atlas files into a summed image
sum_files_into_mask () {
  local out_sum="$1"; shift
  local -a ids=( "$@" )
  local first_done=0
  rm -f "$out_sum"
  for id in "${ids[@]}"; do
    # skip empty / sanitize just in case
    id="${id//[^0-9]/}"
    [ -z "$id" ] && continue
    # Try zero-padded file first, then plain
    idx=$(printf "%02d" "$id")
    f1="${ATLAS_DIR}/PAM50_atlas_${idx}.nii.gz"
    f2="${ATLAS_DIR}/PAM50_atlas_${id}.nii.gz"
    f=""
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

# Binarize the sums to get clean masks
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

# Build optional level args
LVL_ARGS=()
[ -n "$LEVELS" ] && LVL_ARGS=(-vert "$LEVELS")

# Prefer -discfile (newer SCT); fallback to -vertfile if needed
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

# ---- Merge CSVs into one tidy table (robust to SCT column name changes) ----
echo "==> Merge metrics into ${METRICS_OUT}"
python3 - "${SUBJECT_ID}" "${OUT_L}" "${OUT_R}" "${OUT_CSA}" "${METRICS_OUT}" << 'PYCODE'
import sys, pandas as pd, numpy as np
subj, left_csv, right_csv, csa_csv, out_csv = sys.argv[1:6]
L = pd.read_csv(left_csv)
R = pd.read_csv(right_csv)
C = pd.read_csv(csa_csv)

# normalize level column
def norm_level_cols(df):
    if 'level' in df.columns: return df
    for k in ('VertLevel','Label','label'):
        if k in df.columns:
            df = df.rename(columns={k:'level'})
            return df
    return df
L, R, C = map(norm_level_cols, (L,R,C))

# pick a "volume-like" aggregate column
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

# pivot to wide
wide = H.pivot(index='level', columns='side', values='value').reset_index()
wide = wide.rename(columns={'L':'volume_mm3_left', 'R':'volume_mm3_right'})

# bring CSA (choose a CSA/area column)
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

# derived
if {'volume_mm3_left','volume_mm3_right'}.issubset(wide.columns):
    wide['volume_mm3_total'] = wide['volume_mm3_left'].fillna(0) + wide['volume_mm3_right'].fillna(0)
    denom = wide['volume_mm3_total'].replace({0: np.nan})
    wide['asymmetry_index'] = (wide['volume_mm3_right'] - wide['volume_mm3_left']) / denom

wide.insert(0, 'subject', subj)
wide = wide.sort_values('level')
wide.to_csv(out_csv, index=False)
print(f"Wrote {out_csv}")
PYCODE

echo "==> Done."
echo "Outputs in: ${OUTDIR}"
ls -1 "${OUT_L}" "${OUT_R}" "${OUT_CSA}" "${METRICS_OUT}" || true
