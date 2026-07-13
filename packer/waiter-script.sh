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
echo "Waiting for startup script to complete on ($INSTANCE_NAME)..."
start_time=$(date +%s)
timeout=10800
while true; do
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
  full_log=$(gcloud compute instances get-serial-port-output $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID --port=1 2>/dev/null)
  output=$(echo "$full_log" | tail -n 1000)
  if [ $elapsed -gt $timeout ]; then
    echo 'Timeout waiting for startup script!'
    echo 'Dumping full serial log:'
    echo "$full_log"
    exit 1
  fi

  if echo "$full_log" | grep -q 'PACKER_BUILD_SUCCESS'; then
    echo 'Startup script finished successfully! Fetching full log:'
    echo "$full_log"
    break
  fi
  if echo "$full_log" | grep -q 'PACKER_BUILD_FAILURE'; then
    echo 'Startup script FAILED inside the VM:'
    echo "$full_log"
    exit 1
  fi
  echo "Waiting for startup script... ($elapsed seconds elapsed)"
  echo "$output"
  sleep 60
done
