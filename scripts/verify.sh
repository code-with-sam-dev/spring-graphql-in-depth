#!/usr/bin/env bash
# Every claim in the video, measured against the running service. Each mistake
# in mistakes/ is laid over a scratch copy of the service, never the service
# itself, and every step asserts what it expects and fails rather than
# printing something plausible.
#
# Needs Docker, Node 22 or later, JDK 25 and jq.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export JAVA_HOME="${JAVA_HOME_25:-$HOME/.sdkman/candidates/java/25.0.4-amzn}"
JAVA="$JAVA_HOME/bin/java"
WORK=$(mktemp -d)
# VERIFY_KEEP=<dir> keeps every log and response, so the terminal frames in the
# video are the strings these tools printed, copied rather than retyped.
KEEP="${VERIFY_KEEP:-}"
URL=http://localhost:8201

cleanup() {
  for f in "$WORK"/*.pid; do [ -e "$f" ] && kill -9 "$(cat "$f")" 2>/dev/null || true; done
  if [ -n "$KEEP" ]; then mkdir -p "$KEEP" && cp "$WORK"/*.log "$WORK"/*.json "$KEEP"/ 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "CLAIM FAILED: $*" >&2; exit 1; }
say() { echo; echo "== $*"; }

build() {
  local dir="$WORK/shop-$(date +%s%N)"
  cp -R "$ROOT/shop" "$dir"
  rm -rf "$dir/target"
  for m in "$@"; do cp -R "$ROOT/mistakes/$m/shop/." "$dir/"; done
  (cd "$dir" && ./mvnw -q -DskipTests package > "$WORK/build.log" 2>&1) || return 1
  ls "$dir"/target/*.jar | grep -v original | head -1
}
start() {
  : > "$WORK/shop.log"
  "$JAVA" -jar "$1" >> "$WORK/shop.log" 2>&1 &
  echo $! > "$WORK/shop.pid"
  for _ in $(seq 1 120); do
    curl -s -o /dev/null "$URL/api/orders" && return 0
    kill -0 "$(cat "$WORK/shop.pid")" 2>/dev/null || fail "the service exited, see shop.log"
    sleep 0.5
  done
  fail "the service did not start"
}
stop() {
  local p; p=$(cat "$WORK/shop.pid"); kill "$p" 2>/dev/null || true
  while kill -0 "$p" 2>/dev/null; do sleep 0.2; done; rm -f "$WORK/shop.pid"
}
# gql <query> [curl args]: through scripts/ask.sh, logged as the command a reader types
gql() {
  local query=$1; shift
  { printf "scripts/ask.sh '%s'" "$query"; for a in "$@"; do printf " '%s'" "$a"; done; echo; } >> "$WORK/commands.log"
  scripts/ask.sh "$query" "$@"
}
psql_q() { docker compose exec -T postgres psql -U shop -d shop -tAc "$1"; }
mark() { MARK=$(docker compose logs postgres 2>&1 | wc -l); }
selects() {
  docker compose logs postgres 2>&1 | tail -n +"$((MARK + 1))" \
    | grep -E "(statement|execute [^:]*): " | grep -ci "select .* from $1 " || true
}

say "Postgres, fresh"
docker compose down -t 2 > /dev/null 2>&1 || true
docker compose up -d postgres > /dev/null
for _ in $(seq 1 60); do psql_q "select 1" > /dev/null 2>&1 && break; sleep 1; done

say "Build and start the service"
JAR=$(build) || fail "the service did not build"
start "$JAR"
grep -A6 "GraphQL schema inspection" "$WORK/shop.log" | sed 's/^[^ ]* *//' > "$WORK/inspection.log" || true

# --- 1. REST against GraphQL, for two screens ---------------------------------
say "1. The order list screen: id, status, total and the customer's name, twenty times"
REST_BYTES=$(curl -s "$URL/api/orders" | tee "$WORK/rest-list.json" | wc -c | tr -d " ")
REST_CALLS=1
for c in $(jq -r '.[].customerId' "$WORK/rest-list.json"); do
  b=$(curl -s "$URL/api/customers/$c" | wc -c | tr -d " "); REST_BYTES=$((REST_BYTES + b)); REST_CALLS=$((REST_CALLS + 1))
done
LIST_Q='{ orders(first: 20) { edges { node { id status total customer { name } } } } }'
GQL_BYTES=$(gql "$LIST_Q" | tee "$WORK/graphql-list.json" | wc -c | tr -d " ")
[ "$(jq '.data.orders.edges | length' "$WORK/graphql-list.json")" = 20 ] || fail "expected 20 orders"
echo "REST: $REST_CALLS requests, $REST_BYTES bytes. GraphQL: 1 request, $GQL_BYTES bytes." | tee "$WORK/screens.log"

say "   The order detail screen: status, and each line's quantity and product name"
REST_DETAIL=$(curl -s "$URL/api/orders/1" | tee "$WORK/rest-detail.json" | wc -c | tr -d " ")
DETAIL_Q='{ order(id: 1) { status lines { quantity product { name } } } }'
GQL_DETAIL=$(gql "$DETAIL_Q" | tee "$WORK/graphql-detail.json" | wc -c | tr -d " ")
echo "REST detail: $REST_DETAIL bytes, product descriptions included. GraphQL: $GQL_DETAIL bytes." | tee -a "$WORK/screens.log"
[ "$REST_CALLS" -gt 1 ] && [ "$REST_DETAIL" -gt "$GQL_DETAIL" ] || fail "expected REST to under fetch the list and over fetch the detail"

# --- 2. N plus one, three levels deep ----------------------------------------
say "2. Twenty orders, each with its customer, lines and products"
DEEP_Q='{ orders(first: 20) { edges { node { id customer { name } lines { quantity product { name } } } } } }'
count_sql() {
  mark
  gql "$DEEP_Q" > /dev/null
  sleep 1
  echo "$1: customer $(selects customer), order_line $(selects order_line), product $(selects product)" | tee -a "$WORK/nplusone.log"
  SQL_CUSTOMER=$(selects customer); SQL_LINES=$(selects order_line); SQL_PRODUCT=$(selects product)
}
count_sql "batch mapping"
[ "$SQL_CUSTOMER" = 1 ] && [ "$SQL_LINES" = 1 ] && [ "$SQL_PRODUCT" = 1 ] || fail "batched should be 1, 1, 1"
stop; start "$(build n-plus-one)"
count_sql "schema mapping"
[ "$SQL_CUSTOMER" = 20 ] && [ "$SQL_LINES" = 20 ] && [ "$SQL_PRODUCT" = 40 ] || fail "naive should be 20, 20, 40"
stop; start "$JAR"

# --- 3. Errors: what the client is told --------------------------------------
say "3. An order that does not exist"
gql '{ order(id: 999) { id } }' | tee "$WORK/not-found.json" | jq -c .
[ "$(jq -r '.errors[0].extensions.classification' "$WORK/not-found.json")" = NOT_FOUND ] || fail "expected NOT_FOUND"
stop; start "$(build no-exception-resolver)"
gql '{ order(id: 999) { id } }' | tee "$WORK/masked.json" | jq -c .
[ "$(jq -r '.errors[0].extensions.classification' "$WORK/masked.json")" = INTERNAL_ERROR ] || fail "expected the default INTERNAL_ERROR"
grep -q "No order 999" "$WORK/masked.json" && fail "the default should not leak the exception message"
stop; start "$JAR"

# --- 4. HTTP status codes -----------------------------------------------------
say "4. Which status code, for which failure, under which media type"
status() {
  curl -s -o /dev/null -w '%{http_code}' "$URL/graphql" -H 'content-type: application/json' \
    -H "accept: $1" --data "$(jq -n --arg q "$2" '{query: $q}')"
}
for accept in application/json application/graphql-response+json; do
  echo "$accept: syntax error $(status $accept '{ order(id: 1) { id ') , unknown field $(status $accept '{ order(id: 1) { nope } }') , missing order $(status $accept '{ order(id: 999) { id } }')" | tee -a "$WORK/status.log"
done
grep -q "application/graphql-response+json: syntax error 400" "$WORK/status.log" || fail "expected 400 for a syntax error under the new media type"
grep -q "application/json: syntax error 200" "$WORK/status.log" || fail "expected 200 for a syntax error under application/json"
GET_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -G "$URL/graphql" --data-urlencode 'query={ order(id: 1) { id } }')
echo "GET /graphql?query=...: $GET_STATUS" | tee -a "$WORK/status.log"

# --- 5. Field level security --------------------------------------------------
say "5. The customer's email, asked for by three callers"
EMAIL_Q='{ order(id: 1) { customer { name email } } }'
gql "$EMAIL_Q" | tee "$WORK/email-anonymous.json" | jq -c .
gql "$EMAIL_Q" -u clerk:clerk | tee "$WORK/email-clerk.json" | jq -c .
gql "$EMAIL_Q" -u admin:admin | tee "$WORK/email-admin.json" | jq -c .
[ "$(jq -r '.errors[0].extensions.classification' "$WORK/email-anonymous.json")" = UNAUTHORIZED ] || fail "anonymous should be UNAUTHORIZED"
[ "$(jq -r '.errors[0].extensions.classification' "$WORK/email-clerk.json")" = FORBIDDEN ] || fail "clerk should be FORBIDDEN"
[ "$(jq -r '.data.order.customer.email' "$WORK/email-admin.json")" = ada@example.com ] || fail "admin should see the email"
[ "$(jq -r '.data.order.customer.name' "$WORK/email-clerk.json")" = Ada ] || fail "the rest of the response should survive"

# --- 6. Cursor pagination -----------------------------------------------------
say "6. Two pages of three"
PAGE='{ orders(first: 3) { edges { node { id } } pageInfo { hasNextPage endCursor } } }'
gql "$PAGE" | tee "$WORK/page-1.json" | jq -c '.data.orders | {ids: [.edges[].node.id], pageInfo}'
CURSOR=$(jq -r '.data.orders.pageInfo.endCursor' "$WORK/page-1.json")
gql "{ orders(first: 3, after: \"$CURSOR\") { edges { node { id } } pageInfo { hasNextPage } } }" \
  | tee "$WORK/page-2.json" | jq -c '.data.orders | {ids: [.edges[].node.id], pageInfo}'
[ "$(jq -c '[.data.orders.edges[].node.id]' "$WORK/page-2.json")" = '["4","5","6"]' ] || fail "page two should be 4, 5, 6"
echo "the cursor, decoded: $(echo "$CURSOR" | base64 -d 2>/dev/null)" | tee "$WORK/cursor.log"

# --- 7. Aliases against a depth limit ---------------------------------------
say "7. Sixty aliases, two levels deep"
ALIASES=$(python3 -c "print('{ ' + ' '.join(f'o{i}: order(id: {i % 30 + 1}) {{ id }}' for i in range(60)) + ' }')")
mark
gql "$ALIASES" | tee "$WORK/aliases-limited.json" | jq -c '.errors // "answered"'
grep -q "maximum query complexity exceeded" "$WORK/aliases-limited.json" || fail "complexity should reject sixty aliases"
stop; start "$(build depth-only)"
mark
gql "$ALIASES" > "$WORK/aliases-depth-only.json"
sleep 1
N=$(selects orders)
echo "depth limit only: $(jq '.data | length' "$WORK/aliases-depth-only.json") aliases answered, $N order selects" | tee "$WORK/aliases.log"
[ "$N" -ge 60 ] || fail "with depth only, sixty aliases should run sixty queries"
stop; start "$JAR"

# --- 8. Introspection ---------------------------------------------------------
say "8. Asking the schema to describe itself"
gql '{ __schema { queryType { name } } }' | tee "$WORK/introspection-off.json" | jq -c .
grep -q "Introspection has been disabled" "$WORK/introspection-off.json" || fail "introspection should be off"
stop; start "$(build introspection-default)"
gql '{ __schema { queryType { name } } }' | tee "$WORK/introspection-default.json" | jq -c .
[ "$(jq -r '.data.__schema.queryType.name' "$WORK/introspection-default.json")" = Query ] || fail "the default should answer"
stop

# --- 9. A field nobody resolves ----------------------------------------------
say "9. trackingNumber is in the schema, and nothing resolves it"
start "$(build unmapped-field)"
grep -A1 "Unmapped fields" "$WORK/shop.log" | head -1 | sed 's/^[[:space:]]*//' | tee "$WORK/unmapped.log"
grep -q "trackingNumber" "$WORK/unmapped.log" || fail "the startup report should name trackingNumber"
gql '{ order(id: 1) { id trackingNumber } }' | tee "$WORK/unmapped.json" | jq -c .
[ "$(jq -r '.data.order.trackingNumber' "$WORK/unmapped.json")" = null ] && [ "$(jq '.errors // [] | length' "$WORK/unmapped.json")" = 0 ] \
  || fail "the query should return null with no error"
stop; start "$JAR"

# --- 10. A subscription -------------------------------------------------------
say "10. Subscribe to order 5, then ship it"
node scripts/subscribe.mjs 5 > "$WORK/subscription.log" 2>&1 &
SUB=$!
sleep 3
gql 'mutation { shipOrder(id: 5) { id status } }' | jq -c .
wait "$SUB" || fail "the subscription never received the event"
cat "$WORK/subscription.log"
grep -q '"status":"SHIPPED"' "$WORK/subscription.log" || fail "expected a SHIPPED event"
stop

# --- 12. Schema evolution ------------------------------------------------------
say "12. total is renamed to amount: deprecate, then remove"
start "$JAR"
gql '{ order(id: 1) { total amount } }' | tee "$WORK/deprecated.json" | jq -c .
[ "$(jq -r '.data.order.total' "$WORK/deprecated.json")" = 3000 ] && [ "$(jq '.errors // [] | length' "$WORK/deprecated.json")" = 0 ] \
  || fail "a deprecated field should still answer, with no error"
stop; start "$(build field-removed)"
curl -s -w '\nHTTP %{http_code}\n' "$URL/graphql" -H 'content-type: application/json' -H 'accept: application/graphql-response+json' \
  --data '{"query":"{ order(id: 1) { total } }"}' | tee "$WORK/removed.log"
grep -q "HTTP 400" "$WORK/removed.log" && grep -q "ValidationError" "$WORK/removed.log" || fail "removing the field should break the old query"
stop; start "$JAR"

# --- 13. Batching is not caching ----------------------------------------------
say "13. Two root fields asking for the same products, then the same request again"
TWICE='{ a: order(id: 1) { lines { product { name } } } b: order(id: 1) { lines { product { name } } } }'
mark
gql "$TWICE" > /dev/null
sleep 1
FIRST=$(selects product)
gql "$TWICE" > /dev/null
sleep 1
BOTH=$(selects product)
echo "one request, two root fields, same products: $FIRST product selects, one batch per root field; after a second identical request: $BOTH" | tee "$WORK/batching.log"
[ "$FIRST" = 2 ] && [ "$BOTH" = 4 ] || fail "expected one batch per root field, and nothing reused across requests"
stop

# --- 11. Slice tests ----------------------------------------------------------
say "11. The controller, tested without a database"
(cd shop && ./mvnw -q test > "$WORK/tests.log" 2>&1) || fail "the slice tests failed"
(cd shop && ./mvnw test 2>&1 | grep -E "Tests run:.*ShopControllerTests") | tee -a "$WORK/tests.log"

echo
echo "ALL CLAIMS HOLD"
