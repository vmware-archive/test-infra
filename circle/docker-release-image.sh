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

if [[ -n $DOCKER_PASS ]]; then
  echo "Authenticating with Docker Hub..."
  docker login -e $DOCKER_EMAIL -u $DOCKER_USER -p $DOCKER_PASS

  echo "Building '$DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_TAG' release..."
  docker build --rm=false -f $DOCKER_FILE -t $DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_TAG .
  docker tag $DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_TAG $DOCKER_PROJECT/$IMAGE_NAME:latest

  echo "Pushing '$DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_TAG' release..."
  docker push $DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_TAG

  echo "Pushing '$DOCKER_PROJECT/$IMAGE_NAME:latest' release..."
  docker push $DOCKER_PROJECT/$IMAGE_NAME:latest
fi

if [[ -n $GCLOUD_SERVICE_KEY ]]; then
  echo "Authenticating with Google Cloud..."
  echo $GCLOUD_SERVICE_KEY | base64 --decode > ${HOME}/gcloud-service-key.json
  gcloud auth activate-service-account --key-file ${HOME}/gcloud-service-key.json

  echo "Building 'gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$CIRCLE_TAG' release..."
  echo 'ENV BITNAMI_CONTAINER_ORIGIN=GCR' >> Dockerfile
  docker build --rm=false -f $DOCKER_FILE -t gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$CIRCLE_TAG .
  docker tag gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$CIRCLE_TAG gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:latest

  echo "Pushing 'gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$CIRCLE_TAG' release..."
  gcloud docker -- push gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:$CIRCLE_TAG

  echo "Pushing 'gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:latest' release..."
  gcloud docker -- push gcr.io/$GCLOUD_PROJECT/$IMAGE_NAME:latest
fi

if [ -n "$STACKSMITH_API_KEY" ]; then
  echo "Registering image release '$CIRCLE_TAG' with Stacksmith..."
  curl "https://stacksmith.bitnami.com/api/v1/components/$IMAGE_NAME/versions?api_key=$STACKSMITH_API_KEY" \
    -H 'Content-Type: application/json' \
    --data '{"version": "'"${CIRCLE_TAG%-r*}"'", "revision": "'"${CIRCLE_TAG#*-r}"'", "published": true}'
fi

if [[ -n $CHART_NAME && -n $DOCKER_PASS && -n $GITHUB_PASSWORD ]]; then
  CHART_IMAGE=${CHART_IMAGE:-$DOCKER_PROJECT/$IMAGE_NAME:$CIRCLE_TAG}
  CHART_REPO=${CHART_REPO:-https://github.com/bitnami/charts}

  GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-Bitnami Containers}
  GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-containers@bitnami.com}

  # clone the CHART_REPO
  echo "Cloning '$CHART_REPO' repo..."
  git clone --quiet --single-branch $CHART_REPO charts
  cd charts

  # check if chart is present in the CHART_REPO
  CHART_PATH=
  if [ -d "stable/$CHART_NAME" ]; then
    CHART_PATH="stable/$CHART_NAME"
  elif [ -d "incubator/$CHART_NAME" ]; then
    CHART_PATH="incubator/$CHART_NAME"
  fi

  # chart exists in the specified repo
  if [ -n "$CHART_PATH" ]; then
    echo "Preparing chart update..."

    # configure git commit user/email and store github credentials
    git config user.name "$GIT_AUTHOR_NAME"
    git config user.email "$GIT_AUTHOR_EMAIL"
    git config credential.helper store
    echo "https://$GITHUB_USER:$GITHUB_PASSWORD@github.com" > ~/.git-credentials

    # setup development remote (remote needs to exist)
    git remote add development https://$GITHUB_USER@github.com/$GITHUB_USER/$(echo ${CHART_REPO/https:\/\/github.com\/} | tr / -).git

    # generate next chart version
    CHART_VERSION=$(grep '^version:' $CHART_PATH/Chart.yaml | awk '{print $2}')
    CHART_VERSION_NEXT="${CHART_VERSION%.*}.$((${CHART_VERSION##*.}+1))"

    # create a branch
    git checkout -b $CHART_NAME-$CHART_VERSION_NEXT+${CHART_IMAGE#*:}

    # bump chart image version
    echo "Updating chart image to '$CIRCLE_TAG'..."
    sed -i 's|image: '"${CHART_IMAGE%:*}"':.*|image: '"${CHART_IMAGE}"'|' $CHART_PATH/values.yaml

    # bump chart version
    echo "Updating chart version to '$CHART_VERSION_NEXT'..."
    sed -i 's|'"${CHART_VERSION}"'|'"${CHART_VERSION_NEXT}"'|g' $CHART_PATH/Chart.yaml

    # commit and push
    echo "Publishing branch to remote repo..."
    git add $CHART_PATH/Chart.yaml $CHART_PATH/values.yaml
    git commit -m "$CHART_NAME-$CHART_VERSION_NEXT: bump \`${CHART_IMAGE%:*}\` image to version \`${CHART_IMAGE#*:}\`"
    git push development $CHART_NAME-$CHART_VERSION_NEXT+${CHART_IMAGE#*:} -f

    # create PR (do not create PR to kubernetes/charts)
    if [[ $CHART_REPO != https://github.com/kubernetes/charts ]]; then
      export GITHUB_TOKEN=$GITHUB_PASSWORD

      if ! which hub >/dev/null ; then
        echo "Installing 'hub' tool..."
        wget -qO - https://github.com/github/hub/releases/download/v2.2.9/hub-linux-amd64-2.2.9.tgz | tar zxf - --strip 2 hub-linux-amd64-2.2.9/bin/hub && sudo mv hub /usr/local/bin/
      fi

      echo "Creating pull request with '$CHART_REPO' repo..."
      hub pull-request -m "$CHART_NAME-$CHART_VERSION_NEXT: bump \`${CHART_IMAGE%:*}\` image to version \`${CHART_IMAGE#*:}\`"
    fi
  fi
fi
