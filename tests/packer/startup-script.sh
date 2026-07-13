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

# -- Dnf Install Ansible ---
function install_ansible_using_dnf(){
  dnf clean all >> "$DEBUG_LOG" 2>&1 && \
  dnf makecache --refresh >> "$DEBUG_LOG" 2>&1 && \
  dnf install -y epel-release >> "$DEBUG_LOG" 2>&1 && \
  dnf install -y ansible >> "$DEBUG_LOG" 2>&1
}

function create_custom_junit_callback() {
  mkdir -p callback_plugins
  cat <<'EOF' > callback_plugins/my_junit.py
from ansible.plugins.callback import CallbackBase
import os
import xml.etree.ElementTree as ET

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'aggregate'
    CALLBACK_NAME = 'my_junit'

    def __init__(self):
        super(CallbackModule, self).__init__()
        self.test_cases = []

    def v2_runner_on_ok(self, result):
        self.test_cases.append(self._create_test_case(result, 'ok'))

    def v2_runner_on_failed(self, result, ignore_errors=False):
        self.test_cases.append(self._create_test_case(result, 'failed'))

    def _create_test_case(self, result, status):
        tc = ET.Element('testcase', name=result._task.name, classname=result._task.get_name())
        if status == 'failed':
            failure = ET.SubElement(tc, 'failure', message='Task failed')
            failure.text = str(result._result.get('msg', ''))
        return tc

    def v2_playbook_on_stats(self, stats):
        output_dir = os.environ.get('ANSIBLE_JUNIT_OUTPUT_DIR', '/tmp/test-results')
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)

        ts = ET.Element('testsuite', name='ansible_tests')
        for tc in self.test_cases:
            ts.append(tc)

        tree = ET.ElementTree(ts)
        tree.write(os.path.join(output_dir, 'junit.xml'), encoding='utf-8', xml_declaration=True)
EOF
}

log_setup "--- STARTING PACKER SETUP ---"
if [[ "${OS_ID}" == "ubuntu" ]]; then
  wait_for_apt_locks
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >> "$DEBUG_LOG" 2>&1
  apt-get install -y ansible >> "$DEBUG_LOG" 2>&1
else
  wait_for_dnf_locks
  install_ansible_using_dnf
fi

if command -v ansible &> /dev/null; then
  log_setup "Ansible version:"
  ansible --version
else
  log_setup "Ansible is not installed or not in PATH."
fi

# 1. Retrieve and Extract Test Bundle
log_setup "Retrieving and extracting Test bundle..."
mkdir /tmp/tests
if ! curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/test-bundle-base64" -s -f | base64 -d | tar -xzf - -C /tmp/tests; then
  log_setup "CRITICAL ERROR: Failed to decode or extract Test bundle."
  update_metadata_status "failed"
  echo "PACKER_BUILD_FAILURE"
  exit 1
fi
curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/extra-vars-content" > /tmp/extra-vars.json

log_setup "Installing ansible.posix collection..."
ansible-galaxy collection install ansible.posix -p /tmp/tests/collections >> "$DEBUG_LOG" 2>&1 || log_setup "Warning: Failed to install ansible.posix collection."

# 2. Run Tests
log_setup "--- RUNNING TESTS ---"
TEST_START_TIME=$(date +%s)
pushd /tmp/tests
# Read test results GCS path from metadata
TEST_RESULTS_GCS_PATH=$(curl -f -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/test-results-gcs-path" || echo "")

if [[ -n "$TEST_RESULTS_GCS_PATH" ]]; then
  log_setup "Test results will be uploaded to $TEST_RESULTS_GCS_PATH"
  mkdir -p /tmp/test-results

  # Create ansible.cfg to enable junit callback
  # Create custom callback plugin directory
  create_custom_junit_callback

  # Create ansible.cfg to enable custom callback
  cat <<EOF > ansible.cfg
[defaults]
callbacks_enabled = my_junit
collections_paths = /tmp/tests/collections
EOF

  ansible-playbook -i 'localhost,' -c local playbook.yaml --extra-vars "@/tmp/extra-vars.json"
else
  ansible-playbook -i 'localhost,' -c local playbook.yaml --extra-vars "@/tmp/extra-vars.json"
fi

ANSIBLE_EXIT_CODE=$?
popd
TEST_END_TIME=$(date +%s)
log_setup "Ansible finished in $((TEST_END_TIME - TEST_START_TIME)) seconds."

if command -v ansible &> /dev/null; then
  echo "Ansible version:"
  ansible --version
fi

echo "Showing content of /tmp/test-results/"
ls -l /tmp/test-results/
echo "Finished showing content"

# Upload test results if path was provided
if [[ -n "$TEST_RESULTS_GCS_PATH" ]]; then
  log_setup "Uploading test results to $TEST_RESULTS_GCS_PATH..."
  gcs_dest="$TEST_RESULTS_GCS_PATH"

  if gsutil cp -r /tmp/test-results/* "$gcs_dest"; then
    log_setup "Test results uploaded successfully."
  else
    log_setup "CRITICAL ERROR: Failed to upload test results to GCS."
    update_metadata_status "failed"
    echo "PACKER_BUILD_FAILURE"
    exit 1
  fi
fi

# 3. Signal Completion
if [ $ANSIBLE_EXIT_CODE -eq 0 ]; then
  log_setup "Packer build steps completed successfully."
  echo "PACKER_BUILD_SUCCESS"
  signal_packer_completion
else
  log_setup "Packer build steps completed unsuccessfully."
  # Signal failure to GCE metadata
  update_metadata_status "failed"
  echo "PACKER_BUILD_FAILURE"
fi
