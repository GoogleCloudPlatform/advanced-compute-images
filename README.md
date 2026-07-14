# ACI (Advanced Compute Images) VM Images

This repository contains Packer and Ansible scripts for building modular, multi-layered VM images for AI and HPC workloads on Google Cloud.

## Repository Structure

```
/
├── cloudbuild.yaml
├── packer/
│   ├── builds/
│   │   └── ubuntu-2204-slurm-gpu-dev.pkrvars.hcl
│   ├── main.pkr.hcl
│   └── variables.pkr.hcl
├── ansible/
│   ├── playbook.yaml
│   ├── roles/
│   │   ├── os_configs/
│   │   ├── container_tools/
│   │   ├── nvidia_stack/
│   │   ├── slurm_prereqs/
│   │   └── ...
│   ├── vars/
│   │   ├── common.yml
│   │   ├── ubuntu.yml
│   │   ├── rocky.yml
│   └── ansible.cfg
├── examples/
│   └── build_custom_image.sh
└── README.md
```

*   **cloudbuild.yaml**: Google Cloud Build configuration file to trigger Packer builds.
*   **/packer**: Contains the core Packer template (`main.pkr.hcl`), variable definitions (`variables.pkr.hcl`), and build-specific configurations (`builds/`).
*   **/ansible**: Contains the main Ansible playbook (`playbook.yaml`) and reusable roles.
*   **/ansible/roles**: Contains modular, reusable Ansible roles for specific tasks (e.g., installing container tools, NVIDIA stack, Slurm prerequisites).
*   **/ansible/vars**: Contains variable definitions for Ansible, such as package versions and OS-specific settings.
*   **/examples**: Sample scripts for triggering image builds.

## Image Naming Convention

Images built with this repository follow a standardized naming convention:

Image Family: aci-{hw}-{os}[-{orchestrator}][-{features}]-{arch}
Image Name: {image-family}-v{date}-{build}

*   **Image Family Name**: `aci-{hw}-{os}[-{orchestrator}][-{features}]-{arch}`
    *   Example: `aci-gpu-u2204-slurm-2505-cuda-130-nvidia-580-amd64`

*   **Image Name**: `{image-family}-v{date}-{build}`
    *   Example: `aci-gpu-u2204-slurm-2505-cuda-130-nvidia-580-amd64-v20260409-1`

### Triggering a Build

Image configurations are defined by `.pkrvars.hcl` files in the `packer/builds/` directory. These files serve as the single source of truth for all image build variables (e.g., OS, Slurm version, CUDA version).

To build an image, create or modify a `.pkrvars.hcl` configuration file in that directory, then submit a build to Google Cloud Build using `gcloud builds submit`, specifying which configuration file to use via the `_CONFIG_FILE` substitution in `cloudbuild.yaml`.

**Example:**

To build the image defined by `packer/builds/ubuntu-2204-slurm-gpu-dev.pkrvars.hcl`, trigger a build with:

```bash
gcloud builds submit --project YOUR_PROJECT_ID --config=cloudbuild.yaml --substitutions=_CONFIG_FILE="ubuntu-2204-slurm-gpu-dev.pkrvars.hcl"
```

