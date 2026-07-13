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


DEBUG_LOG="/var/log/packer-setup-debug.log"
# Main setup log for "non-noisy" output (clean logs + ansible)
MAIN_LOG="/var/log/packer-setup.log"

OS_ID=$(awk -F= '$1 == "ID" { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release)
echo "The OS ID is: ${OS_ID}"

# Helper function to print clean, tagged logs to the console AND main log file
function log_setup() {
  local msg="[PACKER-SETUP] $1"
  echo "$msg"
  echo "$msg" >> "$MAIN_LOG"
}

function update_metadata_status() {
  local status="$1"
  local zone
  zone=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" -s | awk -F/ '{print $NF}')
  local name
  name=$(hostname)
  gcloud compute instances add-metadata "$name" --zone="$zone" --metadata=startup-script-status="$status" >/dev/null 2>&1 || log_setup "Warning: Failed to update metadata status to '$status'."
}

function signal_packer_completion() {
  log_setup "Signaling completion to Packer..."
  update_metadata_status "done"
}

# --- Wait for Apt Locks ---
function wait_for_apt_locks() {
  log_setup "Checking for system apt/dpkg locks..."
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    log_setup "Locked: Waiting for other system apt processes to finish..."
    sleep 5
  done
  log_setup "Locks acquired. Proceeding."
}
# --- Wait for Dnf Locks ----
function wait_for_dnf_locks() {
  # Check for common DNF/YUM/RPM lock files. fuser will exit 0 if files are locked.
  while fuser /var/lib/dnf/* >/dev/null 2>&1 || \
        fuser /var/lib/rpm/* >/dev/null 2>&1; do
    log_setup "Locked: Waiting for other system dnf/rpm processes to finish..."
    sleep 5
  done
  log_setup "Locks released. Proceeding."
}

# --- Apt Install Ansible ---
function install_ansible_using_apt(){
  dpkg --configure -a || true
  apt-get update && \
  apt-get install -f -y && \
  apt-get install -y software-properties-common && \
  apt-get install -y ansible
}

# -- Dnf Install Ansible ---
function install_ansible_using_dnf(){
  dnf clean all >> "$DEBUG_LOG" 2>&1 && \
  dnf makecache --refresh >> "$DEBUG_LOG" 2>&1 && \
  dnf install -y epel-release >> "$DEBUG_LOG" 2>&1 && \
  dnf install -y ansible >> "$DEBUG_LOG" 2>&1
}

log_setup "--- STARTING PACKER SETUP ---"

# 1. Wait for apt lock / cloud-init if available
if [[ -x "/usr/bin/cloud-init" ]]; then
  /usr/bin/cloud-init status --wait > "$DEBUG_LOG" 2>&1
fi

log_setup "Installing Ansible and dependencies (this may take a moment)..."

# 1. Wait for locks and install Ansible and its dependencies
if ! (
  if [[ "${OS_ID}" == "ubuntu" ]]; then
    wait_for_apt_locks
    export DEBIAN_FRONTEND=noninteractive
    install_ansible_using_apt
  else
    wait_for_dnf_locks
    install_ansible_using_dnf
  fi
) >> "$DEBUG_LOG" 2>&1; then
  log_setup "CRITICAL ERROR: Installation failed."
  log_setup "Dumping the last 50 lines of the debug log for troubleshooting:"
  echo "------------------ DEBUG LOG START ------------------"
  tail -n 50 "$DEBUG_LOG"
  echo "------------------ DEBUG LOG END ------------------"
  # Signal failure to GCE metadata
  update_metadata_status "failed"
  echo "PACKER_BUILD_FAILURE"
  exit 1
fi

# 2. Retrieve and Extract Ansible Bundle
log_setup "Retrieving and extracting Ansible bundle..."
mkdir /tmp/ansible
if ! curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ansible-bundle-base64" -s -f | base64 -d | tar -xzf - -C /tmp/ansible; then
  log_setup "CRITICAL ERROR: Failed to decode or extract Ansible bundle."
  update_metadata_status "failed"
  echo "PACKER_BUILD_FAILURE"
  exit 1
fi
curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/extra-vars-content" > /tmp/extra-vars.json
# log_setup "Listing extracted files in /tmp/ansible:"
# ls -R /tmp/ansible | tee -a "$MAIN_LOG"

# 3. Run Ansible
log_setup "--- RUNNING ANSIBLE ---"
ANSIBLE_START_TIME=$(date +%s)
pushd /tmp/ansible
ANSIBLE_EXIT_CODE=0
ansible-playbook -i 'localhost,' -c local playbook.yaml --extra-vars "@/tmp/extra-vars.json" || ANSIBLE_EXIT_CODE=$?
popd
ANSIBLE_END_TIME=$(date +%s)
log_setup "Ansible finished in $((ANSIBLE_END_TIME - ANSIBLE_START_TIME)) seconds."

function run_cleanup() {
  log_setup "--- Running Final Cleanup Script ---"
  local build_user="packer"
  # Truncate major logs
  truncate -s 0 /var/log/syslog
  truncate -s 0 /var/log/auth.log
  # Remove other log files
  find /var/log -type f \( -name "*.log" -o -name "*.1" -o -name "*.gz" \) -delete
  # Remove bash history
  find / -xdev -type f -name ".bash_history" -delete
  # Remove SSH keys
  rm -f /root/.ssh/authorized_keys
  rm -f "/home/${build_user}/.ssh/authorized_keys"
  # Clean temp directories, leaving Ansible's own temp files untouched for now
  find /tmp /var/tmp -mindepth 1 ! -name 'ansible_*' -delete
  sync
  if [[ "${OS_ID}" == "ubuntu" ]]; then
    wait_for_apt_locks
    # Removing Ansible installation as CTK blueprints have their own installation setup
    apt-get purge -y ansible
    apt-get autoremove -y
    log_setup "Ansible removed."
  else
    wait_for_dnf_locks
    if dnf list installed ansible &>/dev/null; then
        dnf remove -y ansible
        log_setup "Ansible removed."
    fi
  fi
  log_setup "--- Cleanup Complete ---"
}

# 4. Signal Completion
if [ $ANSIBLE_EXIT_CODE -eq 0 ]; then
  log_setup "Packer build steps completed successfully."
  echo "PACKER_BUILD_SUCCESS"
  run_cleanup
  signal_packer_completion
else
  log_setup "Packer build steps completed unsuccessfully."
  # Signal failure to GCE metadata
  update_metadata_status "failed"
  echo "PACKER_BUILD_FAILURE"
fi
