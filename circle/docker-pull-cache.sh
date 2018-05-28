#!/bin/bash -e

# Copyright 2017 Bitnami
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

CIRCLE_CI_FUNCTIONS_URL=${CIRCLE_CI_FUNCTIONS_URL:-https://raw.githubusercontent.com/bitnami/test-infra/master/circle/functions}
source <(curl -sSL $CIRCLE_CI_FUNCTIONS_URL)

if [[ -n $RELEASE_SERIES_LIST ]]; then
  IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
  IFS=',' read -ra DISTRIBUTIONS_ARRAY <<< "${DISTRIBUTIONS_LIST:-${DEFAULT_DISTRO}}"
  for distro in "${DISTRIBUTIONS_ARRAY[@]}"; do
    for rs in "${RELEASE_SERIES_ARRAY[@]}"; do
      tag=${rs}-${CIRCLE_BRANCH}
      if ! is_default_distro "${distro}"; then
          tag="${rs}-${distro}-${CIRCLE_BRANCH}"
      fi
      docker_pull $DOCKER_PROJECT/$IMAGE_NAME:${tag} || true
    done
  done
else
  docker_pull $DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_BRANCH || true
fi
