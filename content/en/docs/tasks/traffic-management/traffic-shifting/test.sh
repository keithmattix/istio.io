#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2154

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e
set -u
set -o pipefail

GATEWAY_API="${GATEWAY_API:-false}"

source "tests/util/samples.sh"

# @setup profile=default

kubectl label namespace default istio-injection=enabled --overwrite
startup_curl_sample # needed for sending test requests with curl
CURL_POD=$(kubectl get pod -l app=curl -n default -o 'jsonpath={.items..metadata.name}')

# launch the bookinfo app
startup_bookinfo_sample

# Verification util
# reviews_v3_traffic_percentage
# gets the % of productpage requests with reviews from reviews:v3 service
# TODO: generalize this function and move to samples.sh so it can be reused by
#       other tests that check traffic distribution.
function reviews_v3_traffic_percentage() {
  set +e
  local total_request_count=100
  local v3_count=0
  local v3_search_string="glyphicon glyphicon-star" # search string present in reviews_v3 response html
  for ((i = 1; i <= total_request_count; i++)); do
    if (kubectl exec "${CURL_POD}" -c curl -n "default" -- curl -sS http://productpage:9080/productpage | grep -q "$v3_search_string"); then
      v3_count=$((v3_count + 1))
    fi
  done
  set -e
  function is_in_range() {
    local tol=10 #tolerance
    local lower_bound=$(($2 - tol))
    local upper_bound=$(($2 + tol))
    if ((lower_bound < $1 && $1 < upper_bound)); then
      return 0
    fi
    return 1
  }
  declare -a ranges=(0 25 50 75 100)
  for i in "${ranges[@]}"; do
    if is_in_range $v3_count "$i"; then
      echo "$i"
    fi
  done
}

# Step 1 configure all traffic to v1

if [ "$GATEWAY_API" == "true" ]; then
    _verify_same snip_gtw_config_all_v1 "httproute.gateway.networking.k8s.io/reviews created"
else
    expected="virtualservice.networking.istio.io/productpage created
virtualservice.networking.istio.io/reviews created
virtualservice.networking.istio.io/ratings created
virtualservice.networking.istio.io/details created"
    _verify_same snip_config_all_v1 "$expected"

    _wait_for_resource virtualservice default productpage
    _wait_for_resource virtualservice default reviews
    _wait_for_resource virtualservice default ratings
    _wait_for_resource virtualservice default details
fi

# Step 2: verify no rating stars visible, (reviews-v3 traffic=0%)

_verify_same reviews_v3_traffic_percentage 0

# Step 3: switch 50% traffic to v3

if [ "$GATEWAY_API" == "true" ]; then
    _verify_same snip_gtw_config_50_v3 "httproute.gateway.networking.k8s.io/reviews configured"
else
    _verify_same snip_config_50_v3 "virtualservice.networking.istio.io/reviews configured"

    _wait_for_resource virtualservice default reviews
fi

# Step 4: Confirm the rule was replaced

if [ "$GATEWAY_API" == "true" ]; then
    _verify_lines snip_gtw_verify_config_50_v3 "
    + message: Route was valid
    + reason: Accepted
    "
else
    _verify_elided snip_verify_config_50_v3 "$snip_verify_config_50_v3_out"
fi

# Step 5: verify rating stars visible 50% of the time

_verify_same reviews_v3_traffic_percentage 50

# Step 6: route 100% traffic to v3

if [ "$GATEWAY_API" == "true" ]; then
    snip_gtw_config_100_v3
else
    snip_config_100_v3

    _wait_for_resource virtualservice default reviews
fi

_verify_same reviews_v3_traffic_percentage 100

# @cleanup
if [ "$GATEWAY_API" != "true" ]; then
    snip_cleanup
    cleanup_bookinfo_sample
    cleanup_curl_sample
    kubectl label namespace default istio-injection-
fi
