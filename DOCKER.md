# GOUHFI pipeline Docker image

A self-contained image that runs the **complete GOUHFI 2.0 pipeline on a single image with one
command**: conforming, brain extraction, subcortical segmentation, cortical parcellation,
FreeSurfer label conversion and reorientation back onto the input grid.

It complements the upstream `Dockerfile` / `docker-compose.yml` (kept unchanged), which expose
the individual `run_*` commands and expect the model weights to be mounted at run time. This
image instead bakes the weights and the ANTsPyNet brain-extraction weights into the image, so it
needs no volumes besides input/output and no internet access, which makes it suitable for
clusters (e.g. converted to an Apptainer/Singularity image).

| | upstream `Dockerfile` | this `Dockerfile.pipeline` |
|---|---|---|
| Weights | mounted at `/opt/gouhfi/trained_model` | included (~7.5 GB per model) |
| ANTsPyNet weights | downloaded on first run | included |
| Default command | `run_gouhfi --help` | `gouhfi_pipeline <input> <output>` |
| Image size | ~9 GB | ~30 GB with the 3 models |

## 1. Model weights

Unzip the model archives into `trained_model/` so that it contains:

```
trained_model/
├── Dataset020_gouhfi_2p0n2/   GOUHFI 2.0 subcortical segmentation   (required)
├── Dataset024_gouhfi_parc/    GOUHFI 2.0 cortical parcellation      (required unless you only use --skip_parc)
└── Dataset014_gouhfi/         GOUHFI 1.0 model, used by --v1         (optional; remove it to save ~8 GB)
```

Downloads: [Zenodo 17920473](https://zenodo.org/records/17920473) or
[Hugging Face mafortin/GOUHFI2p0](https://huggingface.co/mafortin/GOUHFI2p0)
(`gouhfi_2p0_brain_seg.zip`, `gouhfi_2p0_parc.zip`, `GOUHFI.zip`).

## 2. Build

```bash
./build_docker.sh                 # -> gouhfi:2.0.1 and gouhfi:latest
./build_docker.sh gouhfi 2.0.1    # explicit name/tag
```

The script checks that the weights are present, uses `sudo` automatically if your user cannot
reach the Docker daemon, and builds with BuildKit (required: `Dockerfile.pipeline.dockerignore`
overrides the upstream `.dockerignore`, which excludes the weights). The first build takes a
while: ~20 GB of weights are copied, Python dependencies are installed and the ANTsPyNet
brain-extraction weights are pre-cached (needs internet during the build). Add
`--build-arg PRECACHE_ANTSPYNET=0` after the tag to skip the pre-caching.

## 3. Run

```bash
docker run --rm --gpus all --shm-size=16g \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -v /path/to/input:/input \
  -v /path/to/output:/output \
  gouhfi:2.0.1 \
  /input/sub-004_ses-01_T1w.nii.gz /output/sub-004_ses-01_T1w_seg.nii.gz
```

Produces:

- `/output/sub-004_ses-01_T1w_seg.nii.gz` – subcortical segmentation (FreeSurfer labels)
- `/output/sub-004_ses-01_T1w_seg_parc.nii.gz` – cortical parcellation (DKT labels)

Both are written on the voxel grid and orientation of the input image.

Flags:

- `--shm-size=16g`: nnU-Net's worker processes need more shared memory than Docker's 64 MB default.
- `-e HOST_UID/HOST_GID`: output files are owned by you instead of root.
- `--gpus all`: requires the NVIDIA Container Toolkit. Without a GPU add `--cpu` at the end of
  the command (expect ~100x slower inference).

### Variants

```bash
# choose the parcellation file name explicitly (3rd positional argument)
... gouhfi:2.0.1 /input/img.nii.gz /output/img_aseg.nii.gz /output/img_aparc.nii.gz

# segmentation only (no cortical parcellation)
... gouhfi:2.0.1 /input/img.nii.gz /output/img_seg.nii.gz --skip_parc

# original GOUHFI 1.0 model (Dataset014), single segmentation output
... gouhfi:2.0.1 /input/img.nii.gz /output/img_seg.nii.gz --v1

# fewer folds (faster) / CPU
... gouhfi:2.0.1 /input/img.nii.gz /output/img_seg.nii.gz --folds "0 1" --cpu
```

Any option other than the paths is forwarded to `run_gouhfi`. The brain-extraction modality is
guessed from the filename (`T2`/`TSE` → t2, otherwise t1); override with `-e GOUHFI_MODALITY=t2`.

### Other commands

If the first argument is a command instead of a file, it is executed directly:

```bash
docker run --rm gouhfi:2.0.1 run_gouhfi --help
docker run --rm --gpus all --shm-size=16g -v /data:/data gouhfi:2.0.1 run_gouhfi -i /data/renamed -o /data/out
docker run --rm -it gouhfi:2.0.1 bash
```

### Apptainer / Singularity (HPC)

```bash
apptainer build gouhfi-2.0.1.sif docker-daemon://gouhfi:2.0.1
apptainer run --nv gouhfi-2.0.1.sif /path/in/img.nii.gz /path/out/img_seg.nii.gz
```

The wrapper copies the pre-cached ANTsPyNet weights to a writable temporary directory when the
image is read-only, so no network access is needed. (Not tested on a cluster yet.)

## 4. Smoke test

```bash
docker run --rm gouhfi:2.0.1 run_gouhfi --help
docker run --rm --gpus all --shm-size=16g \
  -v "$PWD/test_data/input-images-raw:/input" -v "$PWD/test_out:/output" \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  gouhfi:2.0.1 /input/sub004-t1w-07iso_0000.nii.gz /output/sub004_seg.nii.gz
```

## Troubleshooting

- **`Background workers died` / `RuntimeError`** – increase `--shm-size` (16g, then 32g).
- **`Could not find cuda drivers` from TensorFlow** – harmless; TensorFlow is only used for brain
  extraction on CPU. GOUHFI inference uses PyTorch (`--gpus all`).
- **Pipeline failed** – the temporary working directory (`/tmp/gouhfi_XXXXXX` inside the
  container) is kept on failure; run with `-it ... bash` or mount `/tmp` to inspect it.
- **GPU check** – `docker run --rm --gpus all gouhfi:2.0.1 python -c "import torch; print(torch.cuda.is_available())"`

## Files

- `Dockerfile.pipeline` – image definition (based on the upstream `Dockerfile`)
- `Dockerfile.pipeline.dockerignore` – build context (includes `trained_model/`)
- `docker/gouhfi_pipeline.sh` – the one-command pipeline wrapper (installed as `gouhfi_pipeline`)
- `docker/precache_antspynet.py` – build-time download of the ANTsPyNet brain-extraction weights
- `docker/entrypoint.sh` – upstream entrypoint (HOST_UID/HOST_GID privilege drop)
- `build_docker.sh` – build helper
