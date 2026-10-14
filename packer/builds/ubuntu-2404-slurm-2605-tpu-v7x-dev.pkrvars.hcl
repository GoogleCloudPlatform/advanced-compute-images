# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build definition for TPU v7x

image_os                 = "ubuntu2404"
cpu_arch                 = "x86_64"
orchestrator             = "slurm"
hw_type                  = "tpu"
release_track            = "dev"
build_number             = "1"
# Required by packer/variables.pkr.hcl; ignored while source_image is set.
source_image_family      = "ubuntu-accel-2404-amd64-tpu-tpu7x"
source_image_project_id  = "ubuntu-os-accelerator-images"
slurm_version            = "26.05.4"
build_slurm_from_git_ref = "tpu-2605"
zone                     = "us-central1-a"
machine_type             = "c2-standard-8"
disk_size                = "50"
disk_type                = "pd-ssd"
python_version           = "3.12"
tpu_version              = "tpu7x"

# --- Feature Controls & Customizations ---
# Add extra contrib roles from roles/contrib/ (e.g. ["acme_monitoring"])
ansible_extra_roles     = []

# Exclude any platform or contrib roles (e.g. ["spack", "cloud_monitoring"])
ansible_exclude_roles   = []
