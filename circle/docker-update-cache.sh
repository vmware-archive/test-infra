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

DOCKER_FILE="Dockerfile"
if [ -f ".codenvy.dockerfile" ]; then
  DOCKER_FILE=".codenvy.dockerfile"
fi

if [ -n "$DOCKER_PASS" ]; then
  echo "Authenticating with Docker Hub..."
  docker login -e $DOCKER_EMAIL -u $DOCKER_USER -p $DOCKER_PASS

  echo "Building image..."
  docker build --rm=false -f $DOCKER_FILE -t $DOCKER_PROJECT/$IMAGE_NAME:_ .

  echo "Updating build cache..."
  docker push $DOCKER_PROJECT/$IMAGE_NAME:_
fi
