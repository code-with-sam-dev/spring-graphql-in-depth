#!/usr/bin/env bash
# Send one GraphQL query and print the JSON that comes back.
#
#   scripts/ask.sh '{ order(id: 1) { id status } }'
#   scripts/ask.sh '{ order(id: 1) { customer { email } } }' -u admin:admin
#
# Extra arguments go to curl.
set -euo pipefail
query=$1; shift
curl -s http://localhost:8201/graphql -H 'content-type: application/json' "$@" \
  --data "$(jq -n --arg q "$query" '{query: $q}')"
