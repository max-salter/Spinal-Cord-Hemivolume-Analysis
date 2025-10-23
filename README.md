# 🧠 Spinal Cord Hemivolume Quantification Pipeline (SCT-based)

This repository contains a reproducible **Bash + Python** pipeline for computing **left/right spinal cord hemivolumes per vertebral level** from sagittal T2-weighted MRI DICOM series using the **Spinal Cord Toolbox (SCT)**.

The pipeline automatically:
- Converts **DICOM → NIfTI**
- Segments the spinal cord
- Labels vertebral levels (C2–C8 by default)
- Splits the cord into **left/right hemicords**
- Quantifies **cross-sectional area (CSA)** and **hemivolume** per level
- Computes **asymmetry indices**
- Outputs tidy `.csv` tables ready for analysis or publication

---

## 📁 Repository Contents

```
├── sct_hemi_metrics.sh               ← main pipeline script
├── README.md                         ← this documentation
└── (outputs per subject appear in working directory when run)
```

Each subject folder produced by the script (named automatically from DICOM path metadata) will contain:

```
<Subject_ID>/
│
├── nifti/                                   ← converted DICOMs (.nii.gz)
│
├── <Subject_ID>_T2_RPI.nii.gz               ← reoriented sagittal T2 image
├── <Subject_ID>_sc.nii.gz                   ← spinal cord segmentation
├── <Subject_ID>_sc_labeled.nii.gz           ← vertebral level labels
├── <Subject_ID>_sc_labeled_discs.nii.gz     ← intervertebral disc map
│
├── <Subject_ID>_hemi_left.nii.gz            ← left hemicord mask
├── <Subject_ID>_hemi_right.nii.gz           ← right hemicord mask
│
├── <Subject_ID>_left_hemivol_perlevel.csv   ← per-level left metrics
├── <Subject_ID>_right_hemivol_perlevel.csv  ← per-level right metrics
├── <Subject_ID>_csa_perlevel.csv            ← whole-cord CSA metrics
├── <Subject_ID>_metrics_perlevel.csv        ← tidy merged summary
│
├── warp_curve2straight.nii.gz               ← straightening warp
├── warp_straight2curve.nii.gz               ← inverse warp
├── straight_ref.nii.gz, straightening.cache ← SCT intermediates
└── labels.nii.gz                            ← diagnostic output
```

---

## 🧠 Overview of the Processing Pipeline

### Step 1. DICOM → NIfTI Conversion
- **Tool:** `dcm2niix`
- **Input:** DICOM directory containing a sagittal T2 sequence
- **Output:** `.nii.gz` file in `/nifti` subfolder
- **Purpose:** Converts scanner-native DICOMs to NIfTI with standardized orientation and metadata.

### Step 2. Reorientation to RPI
- **Tool:** `sct_image -setorient RPI`
- **Purpose:** Ensures the image is in **Right–Posterior–Inferior (RPI)** orientation, required by SCT.

### Step 3. Spinal Cord Segmentation
- **Tool:** `sct_deepseg_sc -c t2`
- **Output:** `<Subject_ID>_sc.nii.gz`
- **Purpose:** Performs deep-learning spinal cord segmentation.

### Step 4. Vertebral Level Labeling
- **Tool:** `sct_label_vertebrae -c t2`
- **Output:** `<Subject_ID>_sc_labeled.nii.gz`
- **Purpose:** Assigns integer vertebral labels (C1 = 1, C2 = 2, …).

### Step 5. Hemicord Mask Creation
- **Tool:** Embedded Python script using `nibabel`
- **Input:** Full spinal cord segmentation
- **Output:** Left/right hemicord masks (`*_hemi_left/right.nii.gz`)
- **Logic:** Splits each axial slice at the x-coordinate of the segmentation’s center of mass.

### Step 6. Per-Level Metrics Extraction
- **Tool:** `sct_process_segmentation`
- **Purpose:** Computes per-level shape and area metrics for:
  - Left hemicord
  - Right hemicord
  - Whole cord (CSA)

### Step 7. Merging and Cleaning
- **Tool:** Embedded Python merge block (using `pandas`)
- **Output:** `<Subject_ID>_metrics_perlevel.csv`

| Column | Description |
|:--|:--|
| `subject` | Derived subject identifier |
| `level` | Vertebral level (integer) |
| `CSA_mm2` | Mean cross-sectional area (total cord) |
| `volume_mm3_left` | Volume of left hemicord |
| `volume_mm3_right` | Volume of right hemicord |
| `volume_mm3_total` | Left + Right |
| `asymmetry_index` | (R − L) / (R + L) |

---

## ⚙️ Usage

### 1. Activate SCT Environment
Run inside **WSL (Windows Subsystem for Linux)** with SCT active:

```bash
conda activate sct
```

### 2. Run the Script
Provide the path to the sagittal T2 DICOM folder:

```bash
./sct_hemi_metrics.sh "/mnt/c/Users/<username>/Desktop/.../SAG_T2_2"
```

Both **Windows paths** (`C:\...`) and **WSL paths** (`/mnt/c/...`) are supported.

### 3. Configure Vertebral Levels
Edit the `LEVELS` variable near the top of the script:

```bash
LEVELS="2:8"   # analyze C2–C8 (default)
LEVELS=""      # analyze all detected levels
LEVELS="3:7"   # analyze C3–C7 only
```

---

## 📊 Output Interpretation

### Per-level CSVs
Contain detailed SCT metrics (area, orientation, diameters, etc.) per vertebral level.

### Merged Summary CSV
Provides concise, publication-ready data per vertebral level.

| subject | level | CSA_mm2 | volume_mm3_left | volume_mm3_right | volume_mm3_total | asymmetry_index |
|:--|:--:|--:|--:|--:|--:|--:|
| Injury_F_53_CSpine_Routine_-_3869894001 | 8 | 33.75 | 403.5 | 416.7 | 820.2 | 0.016 |
| ... | 7 | 39.33 | 372.1 | 391.4 | 763.5 | 0.025 |
| ... | 6 | 41.72 | 410.9 | 402.3 | 813.2 | −0.011 |

---

## 🧩 Dependencies

- **Spinal Cord Toolbox (SCT)** ≥ 6.0.0  
  https://spinalcordtoolbox.com/
- **dcm2niix** ≥ v1.0.2025
- **Python ≥ 3.8**
- Modules (included in SCT): `pandas`, `nibabel`, `numpy`

---

## 🧪 Validation & QC

Visualize results:

```bash
fsleyes Injury_F_53_CSpine_Routine_-_3869894001_T2_RPI.nii.gz         Injury_F_53_CSpine_Routine_-_3869894001_sc_labeled.nii.gz &
```

Verify segmentation and labeling alignment, and left/right mask symmetry.

---

## 📈 Downstream Analysis

```python
import pandas as pd, glob, seaborn as sns, matplotlib.pyplot as plt
dfs = [pd.read_csv(f) for f in glob.glob("*_metrics_perlevel.csv")]
df = pd.concat(dfs)
sns.barplot(data=df, x="level", y="asymmetry_index")
plt.title("Hemicord Volume Asymmetry by Vertebral Level")
plt.axhline(0, color='gray', linestyle='--')
plt.show()
```

---

## ⚠️ Troubleshooting

| Symptom | Cause | Fix |
|:--|:--|:--|
| `ERROR: 'dcm2niix' not found in PATH` | SCT not activated | `conda activate sct` |
| `ERROR: DICOM dir not found` | Path mismatch | Use `/mnt/c/...` path |
| Labeling misaligned | Partial FOV | Manually correct segmentation |
| Missing volume columns | Older SCT | Use updated merge section |

---

## 🧬 Version Control

```
/spine-hemi-analysis
├── sct_hemi_metrics.sh
├── README.md
└── outputs/ (git-ignored)
```

**.gitignore:**
```
*.nii
*.nii.gz
*.csv
*.cache
outputs/
```

---

## 🧾 Citation

De Leener B, Lévy S, Dupont SM, Fonov VS, Stikov N, Collins DL, Callot V, Cohen-Adad J.  
*SCT: Spinal Cord Toolbox, an open-source software for processing spinal cord MRI data.*  
**NeuroImage**, 145 (2017): 24–43.  
[10.1016/j.neuroimage.2016.10.009](https://doi.org/10.1016/j.neuroimage.2016.10.009)

---

## 👤 Author

**Author:** Max Salter  
**Institution:** Spencer Fox Eccles School of Medicine, University of Utah  
**Contact:** *[your email or GitHub handle]*  

---

## 🧭 License

**MIT License** — freely reusable with attribution.

> “Precision is measured in millimeters, but reproducibility is measured in documentation.”
