# Spinal Cord Hemivolume Analysis Pipeline (PAM50-based)

## Overview
This repository contains a fully automated workflow for computing **left and right hemicord volumes** per vertebral level from sagittal T2-weighted MRI scans of the cervical spinal cord.  
The pipeline uses the **Spinal Cord Toolbox (SCT)** and **PAM50 atlas** to perform segmentation, vertebral labeling, template registration, and hemispheric metric extraction.

## Dependencies
### Required Software
| Component | Version | Purpose |
|------------|----------|----------|
| **Spinal Cord Toolbox (SCT)** | ≥ 6.0 | Segmentation, registration, labeling, metrics |
| **dcm2niix** | ≥ 1.0 | DICOM → NIfTI conversion |
| **bash** | Any modern Linux shell | Script execution |
| **Python 3.x** (with `pandas`) | Optional | CSV merging and metrics summary |

### Environment Setup
Activate your SCT environment before running:
```bash
source /path/to/spinalcordtoolbox/bin/activate
```

Ensure the SCT data directory contains the **PAM50 atlas** (default: `/home/username/spinalcordtoolbox/data/PAM50`).

## Workflow Summary

### 1. Input
- **Input:** DICOM folder containing sagittal T2 images.  
- **Output directory:** A new folder automatically created under the working directory using the subject’s ID derived from the DICOM path.

### 2. DICOM Conversion
```bash
dcm2niix -z y -o ./nifti input_dicom_folder/
```
Generates the raw NIfTI image (e.g., `Subject_T2.nii.gz`) stored in `./nifti`.

### 3. Reorientation
```bash
sct_image -i Subject_T2.nii.gz -setorient RPI -o Subject_T2_RPI.nii.gz
```
Ensures consistent orientation for SCT tools.

### 4. Spinal Cord Segmentation
```bash
sct_deepseg_sc -i Subject_T2_RPI.nii.gz -c t2 -o Subject_sc.nii.gz
```
Generates a binary segmentation of the spinal cord.

### 5. Vertebral Labeling
```bash
sct_label_vertebrae -i Subject_T2_RPI.nii.gz -s Subject_sc.nii.gz -c t2
```
Labels vertebral levels and intervertebral discs, producing:
- `*_sc_labeled.nii.gz` (vertebral body map)
- `*_sc_labeled_discs.nii.gz` (disc label map)

### 6. Template Registration
```bash
sct_register_to_template -i Subject_T2_RPI.nii.gz -s Subject_sc.nii.gz -ldisc Subject_sc_labeled_discs.nii.gz -c t2
```
Registers subject anatomy to the **PAM50 template** and creates forward/inverse warps:
- `warp_template2anat.nii.gz`
- `warp_anat2template.nii.gz`

### 7. Atlas Warping and Hemispheric Mask Creation
PAM50 white/gray matter atlas labels are warped into the subject space.  
Left/right IDs are parsed from `info_label.txt` to build:
- `atlas_left_labels_sum.nii.gz`
- `atlas_right_labels_sum.nii.gz`
- Binary masks: `atlas_left_mask_bin.nii.gz`, `atlas_right_mask_bin.nii.gz`
- Hemicord masks (intersection with segmentation):  
  `*_hemi_left.nii.gz`, `*_hemi_right.nii.gz`

### 8. Per-Level Metric Computation
For left and right hemicords:
```bash
sct_process_segmentation -i *_hemi_left.nii.gz -perlevel 1 -discfile *_sc_labeled_discs.nii.gz -vert 2:8 -o *_left_hemivol_perlevel.csv
sct_process_segmentation -i *_hemi_right.nii.gz -perlevel 1 -discfile *_sc_labeled_discs.nii.gz -vert 2:8 -o *_right_hemivol_perlevel.csv
```
For the whole cord:
```bash
sct_process_segmentation -i *_sc.nii.gz -perlevel 1 -discfile *_sc_labeled_discs.nii.gz -vert 2:8 -o *_csa_perlevel.csv
```

### 9. Metric Merging
All CSVs are merged into one per-subject summary with columns:
- `level`
- `volume_mm3_left`
- `volume_mm3_right`
- `volume_mm3_total`
- `CSA_mm2`
- `asymmetry_index` = (R − L) / (R + L)

Output:  
`*_metrics_perlevel.csv`

## Output Files (per subject)

| File | Description |
|------|--------------|
| `*_T2_RPI.nii` | Reoriented input MRI |
| `*_sc.nii` | Spinal cord segmentation |
| `*_sc_labeled.nii` | Vertebral body labels |
| `*_sc_labeled_discs.nii` | Intervertebral disc labels |
| `*_hemi_left.nii`, `*_hemi_right.nii` | Hemicord masks (subject space) |
| `*_left_hemivol_perlevel.csv`, `*_right_hemivol_perlevel.csv` | Per-level hemivolumes |
| `*_csa_perlevel.csv` | Whole-cord CSA per level |
| `*_metrics_perlevel.csv` | Merged summary metrics |
| `warp_template2anat.nii.gz`, `warp_anat2template.nii.gz` | Template ↔ Subject warps |
| `straight_ref.nii`, `straightening.cache` | Straightened-space references |
| `label/atlas/` | Warped PAM50 atlas files |
| `nifti/` | Raw converted NIfTI images |

## Typical Workflow Summary
```
./sct_hemi_metrics_PAM50.sh "/path/to/DICOM_folder"
```
1. Converts DICOM → NIfTI.  
2. Segments the cord.  
3. Labels vertebrae/discs.  
4. Registers subject ↔ PAM50 template.  
5. Builds left/right atlas masks.  
6. Computes per-level hemivolumes and CSA.  
7. Merges all metrics into one CSV.  

All outputs are stored under the subject’s directory (auto-generated in the working folder).

## Output Directory Example

```
Spinal-Cord-Hemivolume-Analysis/
├── label/
│   └── atlas/ (37 PAM50 region files)
├── nifti/
│   └── Subject_T2.nii.gz
├── Injury_F_53_CSpine_Routine_-_3869894001_T2_RPI.nii
├── Injury_F_53_CSpine_Routine_-_3869894001_sc.nii
├── Injury_F_53_CSpine_Routine_-_3869894001_sc_labeled_discs.nii
├── Injury_F_53_CSpine_Routine_-_3869894001_hemi_left.nii
├── Injury_F_53_CSpine_Routine_-_3869894001_hemi_right.nii
├── Injury_F_53_CSpine_Routine_-_3869894001_metrics_perlevel.csv
└── warp_template2anat.nii.gz
```

## Algorithm Summary

1. **Segmentation:** Deep learning–based spinal cord segmentation (`sct_deepseg_sc`).
2. **Labeling:** Automatic vertebral level detection from T2-weighted contrast.
3. **Registration:** PAM50 template non-linearly registered to subject anatomy.
4. **Atlas warping:** Each left/right atlas tract/GM region is warped into subject space.
5. **Hemispheric masking:** Left/right masks combined across regions → intersection with subject segmentation.
6. **Metric extraction:** Volume per level computed for each hemi; CSA computed for full cord.
7. **Asymmetry computation:** Left vs. right volume differences quantified as an asymmetry index.

## Notes

- Default vertebral range analyzed: **C2–C8 (vert 2:8)** — adjustable in the script.  
- PAM50 template includes 37 labeled tracts; left/right IDs defined in `label/atlas/info_label.txt`.  
- Units:
  - Volume: mm³  
  - CSA: mm²
- To visualize results, overlay masks in FSLeyes or ITK-SNAP.

## Citation

> De Leener B, Lévy S, Dupont SM, et al. SCT: Spinal Cord Toolbox, an open-source software for processing spinal cord MRI data. *NeuroImage*, 145:24–43, 2017.

## Author & Contact

**Author:** Maxwell L. Salter  
**Institution:** Spencer Fox Eccles School of Medicine, University of Utah
**Version:** 2025-10-23  
**License:** MIT

