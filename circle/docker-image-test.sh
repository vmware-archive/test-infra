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

CIRCLE_CI_FUNCTIONS_URL=${CIRCLE_CI_FUNCTIONS_URL:-https://raw.githubusercontent.com/tompizmor/test-infra/centos-poc/circle/functions}
source <(curl -sSL $CIRCLE_CI_FUNCTIONS_URL)

# SUPPORTED_BASE_IMAGES will be an array of comma separated base images. Default to debian if not declared
if [[ -z $SUPPORTED_BASE_IMAGES ]]; then
    SUPPORTED_BASE_IMAGES=debian
fi
IFS=',' read -ra SUPPORTED_BASE_IMAGES_ARRAY <<< "$SUPPORTED_BASE_IMAGES"

docker_load_cache

if [[ -n $RELEASE_SERIES_LIST ]]; then
  IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
  for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
    if [[ -n $IMAGE_TAG ]]; then
      if [[ "$IMAGE_TAG" == "$RS"* ]]; then
        for BI in "${SUPPORTED_BASE_IMAGES_ARRAY[@]}"; do
          IMAGE_BUILD_DIR=`get_image_build_dir $RS $BI`
          IMAGE_BUILD_TAG=`get_image_build_tag $RS $BI`
          docker_build $DOCKER_PROJECT/$IMAGE_NAME:$IMAGE_BUILD_TAG $IMAGE_BUILD_DIR || exit 1
        done
      fi
    else
      for BI in "${SUPPORTED_BASE_IMAGES_ARRAY[@]}"; do
        IMAGE_BUILD_DIR=`get_image_build_dir $RS $BI`
        IMAGE_BUILD_TAG=`get_image_build_tag $RS $BI`
        docker_build $DOCKER_PROJECT/$IMAGE_NAME:$IMAGE_BUILD_TAG $IMAGE_BUILD_TAG || exit 1
      done
    fi
  done
else
  docker_build $DOCKER_PROJECT/$IMAGE_NAME . || exit 1
fi

docker_save_cache $DOCKER_PROJECT/$IMAGE_NAME
