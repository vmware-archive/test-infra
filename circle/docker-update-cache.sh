#!/bin/bash -e

# Copyright 2016 Bitnami
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

DOCKERFILE=${DOCKERFILE:-Dockerfile}

log() {
  echo -e "$(date "+%T.%2N") ${@}"
}

info() {
  log "INFO  ==> ${@}"
}

warn() {
  log "WARN  ==> ${@}"
}

error() {
  log "ERROR ==> ${@}"
}

docker_login() {
  info "Authenticating with Docker Hub..."
  docker login -e $DOCKER_EMAIL -u $DOCKER_USER -p $DOCKER_PASS
}

docker_build() {
  info "Building '${1}' image..."
  docker build --rm=false -f $DOCKERFILE -t ${1} ${2}
}

docker_push() {
  info "Pushing '${1}' image..."
  docker push ${1}
}

docker_build_and_push() {
  docker_build ${1} ${2} && docker_push ${1}
}

if [[ -n $DOCKER_PASS ]]; then
  docker_login                                || exit 1
  # RELEASE_SERIES_LIST will be an array of comma separated release series
  if [[ -n $RELEASE_SERIES_LIST ]]; then
    IFS=',' read -ra RELEASE_SERIES_ARRAY <<< "$RELEASE_SERIES_LIST"
    for RS in "${RELEASE_SERIES_ARRAY[@]}"; do
      docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:_ $RS || exit 1
    done
  else
    docker_build_and_push $DOCKER_PROJECT/$IMAGE_NAME:_ "." || exit 1
  fi
fi
