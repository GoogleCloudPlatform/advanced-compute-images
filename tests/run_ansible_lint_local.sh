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

# Change to the root of the repository
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "============================================================"
echo "    Local Ansible Lint Presubmit Simulator"
echo "============================================================"
echo "Creating an isolated temporary Python environment..."

# Create a temporary venv so we don't mess up the user's primary environment
VENV_DIR=$(mktemp -d -t ansible-lint-venv-XXXXXX)
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "Installing ansible and ansible-lint (pinned to v26.6.0 exactly like Louhi CI)..."
pip install --quiet --disable-pip-version-check ansible==10.3.0 ansible-lint==26.6.0

echo "Running ansible-lint on the 'ansible/' directory..."
echo "------------------------------------------------------------"

# Set +e so the script doesn't abort instantly if lint fails
set +e
ansible-lint ansible/
LINT_STATUS=$?
set -e

echo "------------------------------------------------------------"
echo "Cleaning up temporary environment..."
deactivate
rm -rf "$VENV_DIR"

if [ $LINT_STATUS -eq 0 ]; then
    echo "✅ Success: Local lint passed! Your code matches the Louhi presubmit."
else
    echo "❌ Failed: Local lint found issues."
    echo "Please fix the warnings/errors above before submitting your CL to guarantee it passes the Gerrit checks."
fi

exit $LINT_STATUS
