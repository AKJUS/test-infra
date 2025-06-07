#!/usr/bin/env bash

# Copyright 2025 The Kubernetes Authors.
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

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Default test mode
TEST_MODE="kind"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --test-mode)
      TEST_MODE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--test-mode <kind|unit>]"
      exit 1
      ;;
  esac
done

# Validate test mode
if [[ "${TEST_MODE}" != "kind" && "${TEST_MODE}" != "unit" ]]; then
  echo "Invalid test mode: ${TEST_MODE}. Must be either 'kind' or 'unit'."
  echo "Usage: $0 [--test-mode <kind|unit>]"
  exit 1
fi

# install kind
curl -sSL https://kind.sigs.k8s.io/dl/latest/linux-amd64.tgz | tar xvfz - -C "${PATH%%:*}/"

# install depstat and mdttohtml
export WORKDIR=${ARTIFACTS:-$TMPDIR}
export PATH=$PATH:$GOPATH/bin
mkdir -p "${WORKDIR}"
pushd "$WORKDIR"
export GOCACHE="${GOCACHE:-"$(mktemp -d)/cache"}"
go install github.com/kubernetes-sigs/depstat@latest
go install github.com/sgaunet/mdtohtml@latest
popd

# needed by gomod_staleness.py
if ! command -v jq &> /dev/null; then
  apt update && apt -y install jq
fi

# grab the stats before we start
depstat stats -m "k8s.io/kubernetes$(ls staging/src/k8s.io | awk '{printf ",k8s.io/" $0}')" -v > "${WORKDIR}/stats-before.txt"

# get the list of packages to skip from unwanted-dependencies.json
SKIP_PACKAGES=$(jq -r '.spec.pinnedModules | to_entries[] | .key' hack/unwanted-dependencies.json)

# update each dependency to the latest version, skipping the packages above
./../test-infra/experiment/dependencies/gomod_staleness.py \
  --skip ${SKIP_PACKAGES} \
  --patch-output "${WORKDIR}"/latest-go-mod-sum.patch \
  --markdown-output "${WORKDIR}"/differences.md
mdtohtml "${WORKDIR}"/differences.md "${WORKDIR}"/differences.html

# See if update-vendor still works
hack/update-vendor.sh

# gather stats for comparison after running update-vendor
depstat stats -m "k8s.io/kubernetes$(ls staging/src/k8s.io | awk '{printf ",k8s.io/" $0}')" -v > "${WORKDIR}/stats-after.txt"
diff -s -u --ignore-all-space "${WORKDIR}"/stats-before.txt "${WORKDIR}"/stats-after.txt || true

# Do not worry if this fails, it is bound to fail
hack/lint-dependencies.sh || true

# ensure that all our code will compile
hack/verify-typecheck.sh

# run tests based on the selected mode
if [[ "${TEST_MODE}" == "kind" ]]; then
  # run kind based e2e tests
  e2e-k8s.sh
else
  # run unit tests
  make test
fi
