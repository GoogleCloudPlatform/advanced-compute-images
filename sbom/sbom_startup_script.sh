#!/bin/bash
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

set -e
set -o pipefail

# Logs
MAIN_LOG="/var/log/sbom-setup.log"

function log_setup() {
  local msg="[SBOM-SETUP] $1"
  echo "$msg"
  echo "$msg" >> "$MAIN_LOG"
}

function update_metadata_status() {
  local status="$1"
  local zone
  zone=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" -s | awk -F/ '{print $NF}')
  local name
  name=$(hostname -s)
  if ! gcloud compute instances add-metadata "$name" --zone="$zone" --metadata=startup-script-status="$status" 2>&1; then
      log_setup "Warning: Failed to update metadata status to '$status'."
  fi
}

function fail() {
  local msg="$1"
  log_setup "CRITICAL ERROR: $msg"
  update_metadata_status "failed"
  echo "PACKER_BUILD_FAILURE"
  exit 1
}

function success() {
  update_metadata_status "done"
  echo "PACKER_BUILD_SUCCESS"
  exit 0
}

log_setup "--- STARTING SBOM SETUP ---"

# --- SBOM Generation ---
# Retrieve SBOM output path from metadata. This path is expected to be within /workspace/louhi_ws/
# Debug: List available attributes to troubleshoot missing metadata
log_setup "Listing available metadata attributes:"
curl -f -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/" >> "$MAIN_LOG" || log_setup "Failed to list attributes"

SBOM_OUTPUT_PATH=$(curl -f -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/sbom-output-path" || echo "")

if [[ -z "$SBOM_OUTPUT_PATH" ]]; then
  fail "No sbom-output-path metadata provided. SBOM cannot be saved."
fi
log_setup "SBOM will be written to: $SBOM_OUTPUT_PATH"

# Ensure the directory for the SBOM output file exists.
# The path is controlled by the Cloud Build step calling Packer.
mkdir -p "$(dirname "$SBOM_OUTPUT_PATH")" \
  || fail "Failed to create directory for $(dirname "$SBOM_OUTPUT_PATH")"

# Fetch the SBOM generation script from metadata
if curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/sbom-script" -s -f > /tmp/generate_sbom.sh; then
  chmod +x /tmp/generate_sbom.sh
  log_setup "Running SBOM generation script..."
  # Execute generate_sbom.sh and redirect its standard output to the SBOM_OUTPUT_PATH.
  # stderr is also logged to MAIN_LOG.
  if /tmp/generate_sbom.sh > "$SBOM_OUTPUT_PATH" 2>&1 | tee -a "$MAIN_LOG"; then
    log_setup "SBOM successfully generated to $SBOM_OUTPUT_PATH"

    # Retrieve SBOM GCS path and upload
    SBOM_GCS_PATH=$(curl -f -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/sbom-gcs-path" || echo "")
    if [[ -n "$SBOM_GCS_PATH" ]]; then
      log_setup "Uploading SBOM to $SBOM_GCS_PATH..."
      if gsutil cp /tmp/sbom.spdx.json "$SBOM_GCS_PATH"; then
         log_setup "SBOM uploaded successfully."
      else
         fail "Failed to upload SBOM to GCS."
      fi
    else
      log_setup "WARNING: sbom-gcs-path not set. SBOM will not be uploaded."
    fi

    success
  else
    fail "SBOM generation script failed."
  fi
else
  fail "No processable SBOM script found in metadata ('sbom-script')."
fi
