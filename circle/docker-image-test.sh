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

# TODO(jdrios,alejandro): temporary workaround
function handle_error() {
  if [ -z "${CIRCLE_TAG}" ] ; then
    exit 1
  else
    mkdir -p /cache
    touch /cache/layers.tar
    exit 0
  fi
}

# TODO(jdrios,alejandro): temporary workaround
docker_load_cache || true

# Execute custom pre-tests scripts
if [[ -d .circleci/scripts/pre-tests.d/ ]]; then
  for script in $(find .circleci/scripts/pre-tests.d/*.sh | sort -n)
  do
    info "Triggering $script..."
    source $script
  done
fi

if [[ -z $RELEASE_SERIES_LIST ]]; then
  docker_build $DOCKER_PROJECT/$IMAGE_NAME . || handle_error
else
  IFS=',' read -ra DISTRIBUTIONS_ARRAY <<< "${DISTRIBUTIONS_LIST}"
  IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "${RELEASE_SERIES_LIST}"
  for distro in "${DISTRIBUTIONS_ARRAY[@]}"; do
    if [[ "${distro}" == "rhel-"* ]]; then
        echo "${distro} images cannot be built, skipping..."
        continue
    fi

    for rs in "${RELEASE_SERIES_ARRAY[@]}"; do
      rs_dir="${rs}"

      # TODO(jdrios) remove the conditional once debian-8 is fully deprecated
      if [[ "${distro}" != "debian-8" ]]; then
        rs_dir+=/${distro}
      fi

      must_exist=0
      branch=${rs}
      if [[ $rs != *-* ]]; then
        # Release series without variants should be available for all the distros supported
        must_exist=1
        branch=${rs%%-*}
      fi

      if [[ "${must_exist}" == 1 || -f "${rs_dir}/Dockerfile" ]]; then
        if [[ -z "${IMAGE_TAG}" || "${IMAGE_TAG}" == "${branch}"* ]]; then
          docker_build "${DOCKER_PROJECT}/${IMAGE_NAME}:${rs}" "${rs_dir}" || handle_error
        fi
      fi
    done
  done
fi

# Execute custom post-tests scripts
if [[ -d .circleci/scripts/post-tests.d/ ]]; then
  for script in $(find .circleci/scripts/post-tests.d/*.sh | sort -n)
  do
    info "Triggering $script..."
    source $script
  done
fi

# TODO(jdrios,alejandro): temporary workaround
docker_save_cache $DOCKER_PROJECT/$IMAGE_NAME || true
