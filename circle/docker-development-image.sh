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

if [[ -n $DOCKER_PASS ]]; then
  docker_login || exit 1
  if [[ -n $RELEASE_SERIES_LIST ]]; then
    IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
    for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
      for BI in "${SUPPORTED_BASE_IMAGES_ARRAY[@]}"; do
        IMAGE_BUILD_CACHE=`get_image_build_cache $DOCKER_PROJECT $IMAGE_NAME $RS $BI`
        IMAGE_BUILD_TAG=`get_image_build_tag $CIRCLE_BRANCH $BI`
        IMAGE_BUILD_DIR=`get_image_build_dir $RS $BI`
        docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$RS-$IMAGE_BUILD_TAG $IMAGE_BUILD_DIR $IMAGE_BUILD_CACHE || exit 1
      done
    done
  else
    for BI in "${SUPPORTED_BASE_IMAGES_ARRAY[@]}"; do
      IMAGE_BUILD_CACHE=`get_image_build_cache $DOCKER_PROJECT $IMAGE_NAME latest $BI`
      IMAGE_BUILD_TAG=`get_image_build_tag $CIRCLE_BRANCH $BI`
      docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:$IMAGE_BUILD_TAG . $IMAGE_BUILD_CACHE || exit 1
    done
  fi
  dockerhub_update_description || exit 1
fi
