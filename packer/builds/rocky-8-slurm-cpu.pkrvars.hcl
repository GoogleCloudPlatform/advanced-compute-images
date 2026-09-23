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

# Build definition for Rocky 8, Slurm, CPU, Dev track

image_os                 = "rocky8"
cpu_arch                 = "x86_64"
orchestrator             = "slurm"
hw_type                  = "cpu"
release_track            = "dev"
build_number             = "1"
source_image_family      = "rocky-linux-8-optimized-gcp"
source_image_project_id  = "rocky-linux-cloud"
machine_type             = "c3-standard-22"
disk_size                = "50"
disk_type                = "pd-ssd"
apply_os_configs         = "true"

# --- Feature Controls & Customizations ---
# Add extra contrib roles from roles/contrib/ (e.g. ["acme_monitoring"])
ansible_extra_roles     = []

# Exclude any platform or contrib roles (e.g. ["spack", "cloud_monitoring"])
ansible_exclude_roles   = []
