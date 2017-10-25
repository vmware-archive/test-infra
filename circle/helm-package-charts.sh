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

install_helm || exit 1
for chart_yaml in $(find $CIRCLE_WORKING_DIRECTORY -name Chart.yaml)
do
  CHART_DIR=${chart_yaml#*${CIRCLE_WORKING_DIRECTORY}/}
  CHART_DIR=${CHART_DIR%%/Chart.yaml*}
  chart_package ${CHART_DIR##*/} $CIRCLE_WORKING_DIRECTORY/$CHART_DIR $CHART_OUTPUT_DIR/${CHART_DIR%%/*} || exit 1
done
