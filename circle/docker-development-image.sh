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

case $LATEST_TAG_SOURCE in
  LATEST_STABLE) IMAGE_TAG=$CIRCLE_BRANCH ;;
  HEAD) IMAGE_TAG=latest ;;
esac

if [[ -n $DOCKER_PASS ]]; then
  docker_login || exit 1
  if [[ -z $RELEASE_SERIES_LIST ]]; then
    docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$IMAGE_TAG . $DOCKER_PROJECT/$IMAGE_NAME:latest || exit 1
  else
    IFS=',' read -ra DISTRIBUTIONS_ARRAY <<< "${DISTRIBUTIONS_LIST}"
    IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "${RELEASE_SERIES_LIST}"

    if is_base_image "${IMAGE_NAME}"; then
      for rs in "${RELEASE_SERIES_ARRAY[@]}"; do
        rs_dir="${rs}"
        push_tag="${rs}-${IMAGE_TAG}"
        cache_tag="${rs}"

        docker_build_and_push "${DOCKER_PROJECT}/${IMAGE_NAME}:${push_tag}" "${rs_dir}" "${DOCKER_PROJECT}/${IMAGE_NAME}:${cache_tag}" || exit 1
      done
    else
      for distro in "${DISTRIBUTIONS_ARRAY[@]}"; do
        if [[ "${distro}" == "rhel-"* ]]; then
          echo "${distro} images cannot be built, skipping..."
          continue
        fi

        for rs in "${RELEASE_SERIES_ARRAY[@]}"; do
          rs_dir="${rs}"
          push_tag="${rs}-${distro}-${IMAGE_TAG}"
          cache_tag="${rs}-${distro}"

          # TODO(jdrios) remove the conditional once debian-8 is fully deprecated
          if [[ "${distro}" != "debian-8" ]]; then
            rs_dir+=/${distro}
          fi

          must_exist=0
          if [[ $rs != *-* ]]; then
            # Release series without variants should be available for all the distros supported
            must_exist=1
          fi

          if [[ "${must_exist}" == 1 || -f "${rs_dir}/Dockerfile" ]]; then
            docker_build_and_push "${DOCKER_PROJECT}/${IMAGE_NAME}:${push_tag}" "${rs_dir}" "${DOCKER_PROJECT}/${IMAGE_NAME}:${cache_tag}" || exit 1
          fi
        done
      done
    fi
  fi
  dockerhub_update_description || exit 1
fi
