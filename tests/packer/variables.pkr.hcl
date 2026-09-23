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

variable "image_os" {
  type = string
  description = "The OS of the image being built."
}

variable "cpu_arch" {
  type = string
  description = "CPU architecture (e.g. x86_64, arm64)."
}

variable "orchestrator" {
  type = string
  description = "Orchestrator (e.g. slurm)."
}

variable "hw_type" {
  type = string
  description = "Hardware type (e.g. cpu, gpu)."
}

variable "tpu_version" {
  type        = string
  description = "TPU version (e.g. v6e)."
  default     = null
}

variable "release_track" {
  type = string
  description = "Release track (e.g. lts, dev, test)."
}

variable "cuda_version" {
  type = string
  description = "CUDA version."
  default = ""
}

variable "fabric_manager_version" {
  type  = string
  description = "NVIDIA fabric manager version."
  default = "580.65.06"
}

variable "nvidia_driver_package_version" {
  type    = string
  default = "580-server"
}

variable "fabricmanager_deb" {
  type        = string
  description = "NVIDIA fabric manager deb package."
  default     = "nvidia-fabricmanager_580.65.06-1_amd64.deb"
}

variable "build_number" {
  type = string
  description = "Build number for image."
}

variable "build_id" {
  type = string
  description = "Unique ID for the build, provided by Cloud Build."
}

variable "project_id" {
  type = string
  description = "GCP project ID."
}

variable "source_image" {
  type = string
  description = "Source image name for the packer build."
  default = null
}

variable "source_image_family" {
  type = string
  description = "Source image family for the packer build."
}

variable "source_image_project_id" {
  type = string
  description = "Project ID for source image."
}

variable "zone" {
  type = string
  description = "GCP zone for instance creation."
}

variable "machine_type" {
  type = string
  default = "n1-standard-4"
}

variable "disk_size" {
  type = number
  default = 30
}

variable "disk_type" {
  type = string
  default = "pd-ssd"
}

variable "nccl_gib_version" {
  type = string
  default = "1.1.0"
}

variable "nccl_version" {
  type    = string
  default = "2.28.9-1"
}

variable "ansible_exclude_roles" {
  type        = list(string)
  description = "List of predefined or contrib roles to skip/exclude during execution."
  default     = []
}

variable "slurm_version" {
  type = string
  default = "26.05.4"
}

variable "build_slurm_from_git_ref" {
  type        = string
  default     = "6.13.1"
  description = "The slurm-gcp repository git ref (tag or branch) to clone for building Slurm."
}

variable "test_bundle_base64" {
  type = string
  default = ""
}

variable "test_results_gcs_path" {
  type = string
  description = "GCS path to upload test results"
  default = ""
}

variable "install_dcgm" {
  type        = bool
  default     = false
  description = "Flag to gate NVIDIA DCGM installation pending legal approval."
}
