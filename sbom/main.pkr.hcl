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

packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

variable "project_id" {
  type        = string
}

variable "zone" {
  type        = string
}

variable "source_image" {
  type        = string
}

variable "build_id" {
  type        = string
}

variable "sbom_gcs_path" {
  type        = string
  description = "Full GCS path to upload the SBOM to gs://deeplearning-platform-kokoro"
}

variable "machine_type" {
  type    = string
  default = "n1-standard-4"
}

source "googlecompute" "sbom" {
  project_id   = var.project_id
  zone         = var.zone
  source_image = var.source_image
  skip_create_image = true
  ssh_username = "ubuntu"
  use_os_login = "false"
  machine_type = var.machine_type
  disk_size    = 50
  state_timeout="30m"

  instance_name = "packer-sbom-${var.build_id}"
  
  scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  
  communicator = "none"
  omit_external_ip = false
  use_internal_ip  = false
  
  metadata = {
    startup-script = file("sbom_startup_script.sh")
    sbom-script    = file("generate_sbom.sh") 
    startup-script-status = "pending"
    sbom-gcs-path  = var.sbom_gcs_path
    sbom-output-path = "/tmp/sbom_execution.log"
  }
}

build {
  sources = ["source.googlecompute.sbom"]
  provisioner "shell-local" {
     environment_vars = [
        "INSTANCE_NAME=packer-sbom-${var.build_id}",
        "ZONE=${var.zone}",
        "PROJECT_ID=${var.project_id}"
     ]
     inline = [
       "chmod +x ${path.root}/waiter-script.sh",
       "${path.root}/waiter-script.sh"
     ]
  }
}
