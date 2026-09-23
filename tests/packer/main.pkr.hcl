#
# Copyright 2023 Google LLC
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

packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.0",
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

locals {
  has_slurm = var.orchestrator == "slurm" && !contains(var.ansible_exclude_roles, "slurm")
  has_nvidia_stack = var.hw_type == "gpu" && !contains(var.ansible_exclude_roles, "nvidia_stack")

  build_date = formatdate("YYYYMMDD", timestamp())
  ansible_dir = "../ansible"
  ansible_vars = {
    image_os       = var.image_os
    cpu_arch       = var.cpu_arch
    orchestrator   = var.orchestrator
    hw_type        = var.hw_type
    release_track  = var.release_track
    fabric_manager_version = var.fabric_manager_version
    nvidia_driver_package_version = var.nvidia_driver_package_version
    fabricmanager_deb      = var.fabricmanager_deb
    cuda_version   = var.cuda_version
    nccl_gib_version= var.nccl_gib_version
    nccl_version            = var.nccl_version
    install_slurm   = local.has_slurm
    install_nvidia_stack = local.has_nvidia_stack
    install_dcgm    = var.install_dcgm
    exclude_roles           = var.ansible_exclude_roles
    slurm_version           = var.slurm_version
    build_slurm_from_git_ref= var.build_slurm_from_git_ref
  }

  image_family_parts = compact([
    "aci",
    var.hw_type,
    var.tpu_version,
    replace(replace(var.image_os, "ubuntu", "u"), "rocky", "rocky-linux-"),
    local.has_slurm ? "slurm-${join("", slice(split(".", var.slurm_version), 0, 2))}" : null,
    local.has_nvidia_stack ? "cuda-${join("", slice(split(".", var.cuda_version), 0, 2))}" : null,
    local.has_nvidia_stack ? "nvidia-${split(".", var.fabric_manager_version)[0]}" : null,
    var.cpu_arch == "x86_64" ? "amd64" : (var.cpu_arch == "arm64" ? "arm64" : replace(var.cpu_arch, "_", "-")),
    var.release_track == "nightly" ? var.release_track : null
  ])
  image_family_name  = join("-", local.image_family_parts)
  image_name_parts = compact([
    "aci",
    var.hw_type,
    replace(replace(var.image_os, "ubuntu", "u"), "rocky", "rocky-linux-"),
    local.has_slurm ? "slurm-${join("", slice(split(".", var.slurm_version), 0, 2))}" : null,
    local.has_nvidia_stack ? "cuda-${join("", slice(split(".", var.cuda_version), 0, 2))}" : null,
    local.has_nvidia_stack ? "nvidia-${split(".", var.fabric_manager_version)[0]}" : null,
    var.cpu_arch == "x86_64" ? "amd64" : (var.cpu_arch == "arm64" ? "arm64" : replace(var.cpu_arch, "_", "-")),
  ])
  image_name_val = join("-", local.image_name_parts)
}

source "googlecompute" "image" {
  project_id = var.project_id
  zone       = var.zone

  use_os_login = "false"
  ssh_username = "ubuntu"

  source_image_project_id = [var.project_id]
  source_image_family     = local.image_family_name
  source_image            = var.source_image # will default to null and pick latest image from family

  # Naming
  instance_name = "packer-tmp-${var.build_id}" # For communicator-less
  image_name    = "${local.image_name_val}-v${local.build_date}${var.build_number != "" ? "-${var.build_number}" : ""}"
  image_family  = local.image_family_name

  machine_type = (var.hw_type == "gpu" && var.cpu_arch != "arm64") ? "n1-standard-8" : var.machine_type
  disk_size    = var.disk_size
  disk_type    = var.disk_type

  state_timeout = "10m"

  accelerator_count = (var.hw_type == "gpu" && var.cpu_arch != "arm64") ? 2 : 0
  accelerator_type = (var.hw_type == "gpu" && var.cpu_arch != "arm64") ? "projects/${var.project_id}/zones/${var.zone}/acceleratorTypes/nvidia-tesla-t4" : null

  on_host_maintenance = (var.hw_type == "gpu") ? "TERMINATE" : "MIGRATE"

  # We need external IP to download Ansible/Pip packages in the startup script
  omit_external_ip = false
  use_internal_ip  = false

  # --- "No-SSH" Configuration ---
  communicator = "none"
  scopes = [
    "https://www.googleapis.com/auth/cloud-platform"
  ]

  # network Configuration
  image_guest_os_features = [
    "GVNIC",
    "UEFI_COMPATIBLE"
  ]

  skip_create_image = true

  # --- Startup Script & Metadata ---
  metadata = {
    test-bundle-base64 = var.test_bundle_base64
    block-project-ssh-keys = "TRUE"
    extra-vars-content    = jsonencode(local.ansible_vars)
    enable-guest-attributes = "TRUE"
    enable-osconfig = "FALSE"
    enable-oslogin = "FALSE"
    startup-script-status = "pending"
    test-results-gcs-path = var.test_results_gcs_path

    startup-script = file("startup-script.sh")
  }
}

build {
  name    = "aci-image"
  sources = ["sources.googlecompute.image"]

  # --- Waiter Script ---
  # Since communicator is "none", Packer would normally finish immediately.
  # This polls the serial port log until the startup script signals completion or failure.
  provisioner "shell-local" {
    environment_vars = [
      "INSTANCE_NAME=packer-tmp-${var.build_id}",
      "ZONE=${var.zone}",
      "PROJECT_ID=${var.project_id}"
    ]
    inline = ["/bin/sh ${path.root}/waiter-script.sh"]
  }
}
