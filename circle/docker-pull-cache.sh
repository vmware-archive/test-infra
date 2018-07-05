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
  IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "${RELEASE_SERIES_LIST}"
  IFS=',' read -ra DISTRIBUTIONS_ARRAY <<< "${DISTRIBUTIONS_LIST}"
  for distro in "${DISTRIBUTIONS_ARRAY[@]}"; do
    for rs in "${RELEASE_SERIES_ARRAY[@]}"; do
      legacy_tag="${rs}-${CIRCLE_BRANCH}"
      tag="${rs}-${distro}-${CIRCLE_BRANCH}"

      docker_pull $DOCKER_PROJECT/$IMAGE_NAME:${tag} || true
      # TODO(jdrios) remove once debian-8 is fully deprecated
      if [[ "${distro}" == "debian-8" ]]; then
        docker_pull $DOCKER_PROJECT/$IMAGE_NAME:${legacy_tag} || true
      fi
    done
  done
else
  IFS=',' read -ra DISTRIBUTIONS_ARRAY <<< "${DISTRIBUTIONS_LIST}"
  for distro in "${DISTRIBUTIONS_ARRAY[@]}"; do
    tag="${distro}-${CIRCLE_BRANCH}"
    docker_pull $DOCKER_PROJECT/$IMAGE_NAME:${tag} || true
  done
fi
