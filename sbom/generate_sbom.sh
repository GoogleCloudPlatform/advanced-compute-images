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

# Exit immediately if a command exits with a non-zero status.
set -e
echo "--- STARTING SBOM GENERATION ---"

# Ensure required dependencies (jq, curl, tar, coreutils) are installed
echo "Checking required dependencies..."
if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null || ! command -v tar &> /dev/null || ! command -v sha256sum &> /dev/null; then
    echo "Installing missing dependencies..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y jq curl tar coreutils
    elif command -v dnf &> /dev/null; then
        dnf install -y jq curl tar coreutils
    elif command -v yum &> /dev/null; then
        yum install -y jq curl tar coreutils
    else
        echo "Package manager not found. Cannot install dependencies."
        exit 1
    fi
fi

# Install Syft if not present, enforcing SHA-256 verification
if ! command -v syft &> /dev/null; then
    echo "Installing Syft v1.33.0 with SHA-256 checksum verification..."
    ARCH=$(uname -m)
    SYFT_VERSION="v1.33.0"
    if [[ "${ARCH}" == "x86_64" || "${ARCH}" == "amd64" ]]; then
        SYFT_ARCH="linux_amd64"
        SYFT_SHA256="adc1b944a827ed3432bcd9f1dbdbc8fa3c0dca7d3d449e7084c90248c2c6cb50"
    elif [[ "${ARCH}" == "aarch64" || "${ARCH}" == "arm64" ]]; then
        SYFT_ARCH="linux_arm64"
        SYFT_SHA256="6688be30048149df88e5959a756dbab086022a04d0f7497790cd298a9669f49d"
    else
        echo "Unsupported architecture for Syft: ${ARCH}"
        exit 1
    fi

    SYFT_TARBALL="syft_${SYFT_VERSION#v}_${SYFT_ARCH}.tar.gz"
    SYFT_URL="https://github.com/anchore/syft/releases/download/${SYFT_VERSION}/${SYFT_TARBALL}"

    echo "Downloading Syft ${SYFT_VERSION} for ${SYFT_ARCH}..."
    curl -sSfL -o "/tmp/${SYFT_TARBALL}" "${SYFT_URL}"
    echo "Verifying SHA-256 checksum..."
    echo "${SYFT_SHA256}  /tmp/${SYFT_TARBALL}" | sha256sum -c -
    tar -xzf "/tmp/${SYFT_TARBALL}" -C /usr/local/bin syft
    chmod +x /usr/local/bin/syft
    rm -f "/tmp/${SYFT_TARBALL}"
    echo "Syft ${SYFT_VERSION} installed successfully."
else
    echo "Syft is already installed at $(command -v syft)."
fi

# --- START CUDA SBOM AMENDMENT ---
echo "Creating supplementary SBOM for CUDA Toolkit and related APT package metadata..."

# Function to get a specific field from package manager output (apt or dnf)
get_pkg_field() {
  local package="$1"
  local field="$2"

  if command -v apt &> /dev/null; then
    if [[ "${field}" == "Version" ]]; then
      apt show "${package}" 2>/dev/null | grep -P "^Version: " | sed -E "s/^Version: //" | head -n 1 | xargs || echo ""
    elif [[ "${field}" == "Source" ]]; then
      apt show "${package}" 2>/dev/null | grep -P "^APT-Sources: " | sed -E "s/^APT-Sources: //" | head -n 1 | xargs || echo ""
    elif [[ "${field}" == "Description" ]]; then
      apt show "${package}" 2>/dev/null | sed -n '/^Description: /,/^$/p' | tail -n +2 | head -n 1 | xargs || echo ""
    fi
  elif command -v dnf &> /dev/null; then
    if [[ "${field}" == "Version" ]]; then
      local dnf_version=$(dnf info "${package}" 2>/dev/null | grep -E "^Version\s*:" | sed -E "s/^Version\s*:\s*//" | head -n 1 | xargs)
      local dnf_release=$(dnf info "${package}" 2>/dev/null | grep -E "^Release\s*:" | sed -E "s/^Release\s*:\s*//" | head -n 1 | xargs)
      if [[ -n "${dnf_version}" && -n "${dnf_release}" ]]; then
        echo "${dnf_version}-${dnf_release}"
      else
        echo "${dnf_version}"
      fi
    elif [[ "${field}" == "Source" ]]; then
      dnf info "${package}" 2>/dev/null | grep -E "^URL\s*:" | sed -E "s/^URL\s*:\s*//" | head -n 1 | xargs || echo ""
    elif [[ "${field}" == "Description" ]]; then
      dnf info "${package}" 2>/dev/null | grep -E "^Summary\s*:" | sed -E "s/^Summary\s*:\s*//" | head -n 1 | xargs || echo ""
    fi
  fi
}

# Function to generate SPDX JSON for an OS package's metadata
generate_pkg_spdx() {
  local pkg_name="$1"
  local version=$(get_pkg_field "${pkg_name}" "Version")
  local source_loc=$(get_pkg_field "${pkg_name}" "Source")
  local description=$(get_pkg_field "${pkg_name}" "Description")

  if [[ -z "${version}" ]]; then
    echo "Warning: Could not find OS package info for ${pkg_name}. Skipping." >&2
    return 1
  fi

  local spdxid="SPDXRef-Package-OS-${pkg_name//./-}"
  # URL encode spaces in Source for downloadLocation
  local download_loc="${source_loc// /%20}"
  if [[ -z "${download_loc}" ]]; then
    download_loc="NOASSERTION"
  fi

  jq -n \
    --arg name "${pkg_name}" \
    --arg spdxid "${spdxid}" \
    --arg version "${version}" \
    --arg dl "${download_loc}" \
    --arg desc "Metadata from OS package repository for package '${pkg_name}'. Description: ${description}" \
    '{
      name: $name,
      SPDXID: $spdxid,
      versionInfo: $version,
      licenseConcluded: "NVIDIA-CUDA-EULA",
      downloadLocation: $dl,
      comment: $desc
    }'
}

# Extract CUDA version from runfile installation to determine package names
CUDA_VERSION=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n -E 's/.*release ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -n 1)
if [[ -z "${CUDA_VERSION}" ]]; then
  CUDA_VERSION="unknown"
fi

if [[ "${CUDA_VERSION}" == "unknown" ]]; then
  echo "Warning: Could not determine CUDA version from nvcc. Skipping CUDA amendment creation."
else
  # Extract major.minor for package names (e.g. 12.8 -> 12-8)
  CUDA_MAJOR_MINOR=$(echo "${CUDA_VERSION}" | cut -d. -f1,2)
  CUDA_PKG_SUFFIX="${CUDA_MAJOR_MINOR//./-}"

  # Collect SPDX JSON for specified OS packages
  OS_PACKAGES=("cuda-toolkit-${CUDA_PKG_SUFFIX}" "cuda-toolkit-${CUDA_PKG_SUFFIX}-config-common")
  OS_SPDX_PACKAGES=""
  for pkg in "${OS_PACKAGES[@]}"; do
    if OS_SPDX_JSON=$(generate_pkg_spdx "${pkg}"); then
      if [[ -n "${OS_SPDX_PACKAGES}" ]]; then
        OS_SPDX_PACKAGES="${OS_SPDX_PACKAGES},"
      fi
      OS_SPDX_PACKAGES="${OS_SPDX_PACKAGES}${OS_SPDX_JSON}"
    fi
  done

  CUDA_AMENDMENT_FILE="/tmp/cuda_amendment.spdx.json"
  BUILD_ID=${_BUILD_ID:-$(date +%s)} # Use Cloud Build ID if available

  # Build the amendment file with both runfile and OS package metadata
  cat <<EOF > "${CUDA_AMENDMENT_FILE}"
  {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT-CUDA-Amendment",
    "name": "NVIDIA CUDA Toolkit ${CUDA_VERSION} and OS Package Metadata Amendment",
    "documentNamespace": "https://google.com/spdx/cuda-amendment-${CUDA_VERSION//./-}-${BUILD_ID}",
    "creationInfo": {
      "creators": [
        "Tool: Manual/Scripted Amendment",
        "Organization: Google LLC"
      ],
      "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    },
    "packages": [
      {
        "name": "NVIDIA CUDA Toolkit",
        "SPDXID": "SPDXRef-Package-NVIDIACUDA-${CUDA_VERSION//./-}",
        "versionInfo": "${CUDA_VERSION}",
        "licenseConcluded": "NVIDIA-CUDA-EULA",
        "downloadLocation": "https://developer.nvidia.com/cuda-toolkit-archive",
        "comment": "NVIDIA CUDA Toolkit installed via runfile. Not managed by dpkg."
      }
      ${OS_SPDX_PACKAGES:+, ${OS_SPDX_PACKAGES}}
    ]
  }
EOF
  echo "CUDA amendment file created at: ${CUDA_AMENDMENT_FILE}"
  fi

# Generate base SBOM for the root filesystem using Syft
echo "Generating SBOM for the root filesystem (/) ..."
SYFT_SBOM_FILE="/tmp/syft_sbom.spdx.json"
# The output format is SPDX JSON
sudo /usr/local/bin/syft / -o spdx-json > "${SYFT_SBOM_FILE}"
echo "Syft SBOM generated at: ${SYFT_SBOM_FILE}"

# --- Merge SBOMs ---
if [[ -f "${CUDA_AMENDMENT_FILE}" ]]; then
    echo "Merging Syft SBOM with CUDA amendment..."
    # jq was installed at the beginning of the script
    # Merge the 'packages' arrays from both JSONs.
    # jq -s '.[0] * { packages: (.[0].packages + .[1].packages) }' combines the two files.
    # .[0] refers to the first input file (Syft SBOM), .[1] to the second (CUDA amendment).
    # The top-level fields from .[0] are used, and the 'packages' array is
    # replaced with the concatenation of both 'packages' arrays.
    jq -s '.[0] * { packages: (.[0].packages + .[1].packages) }' "${SYFT_SBOM_FILE}" "${CUDA_AMENDMENT_FILE}" > /tmp/sbom.spdx.json
    echo "Merged SBOM created at: /tmp/sbom.spdx.json"
else
    echo "No CUDA amendment file found. Using Syft SBOM as final SBOM."
    cp "${SYFT_SBOM_FILE}" /tmp/sbom.spdx.json
fi

ls -lh /tmp/sbom.spdx.json
echo "--- FINISHED SBOM GENERATION ---"
