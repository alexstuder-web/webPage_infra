#!/usr/bin/env bash
# ============================================================================
# Cloudflare Tunnel + DNS Reconcile  (idempotent)
#
# Liest scripts/cloudflare-routes.json + .env, gleicht ab:
#   1. Tunnel-Ingress (Hostname → Container:Port)
#   2. DNS-CNAMEs auf den Tunnel
#
# Manuell:        ./scripts/cloudflare-reconcile.sh
# Aus bootstrap:  am Ende von scripts/bootstrap.sh aufgerufen
#
# Routing-Map ändern: scripts/cloudflare-routes.json editieren, dann erneut
# laufen lassen. Nur das Delta wird API-seitig geändert.
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
ROUTES_JSON="scripts/cloudflare-routes.json"
ENV_FILE=".env"

# ---------------------------------------------------------------- Helpers
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err()  { echo -e "\033[1;31m✖ $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------- Pre-flight
[[ -f "$ROUTES_JSON" ]] || err "Keine Routes-Map: $ROUTES_JSON"
[[ -f "$ENV_FILE" ]]   || err "Keine .env — erst ./scripts/decrypt-env.sh"
command -v jq   >/dev/null || err "jq fehlt (apt install jq)"
command -v curl >/dev/null || err "curl fehlt"

# Nur die vier benötigten CF-Werte aus .env lesen — kein set -a/source, damit
# OpenAI/RAPT/Brewfather/Postgres-Keys nicht in den Reconcile-Prozess lecken.
_cf_get() {
  local key="$1"
  local val
  val="$(grep -E "^${key}=[[:print:]]" "$ENV_FILE" | head -1 | cut -d= -f2-)"
  printf '%s' "$val"
}

CLOUDFLARE_API_TOKEN="$(_cf_get CLOUDFLARE_API_TOKEN)"
CLOUDFLARE_ACCOUNT_ID="$(_cf_get CLOUDFLARE_ACCOUNT_ID)"
CLOUDFLARE_ZONE_ID="$(_cf_get CLOUDFLARE_ZONE_ID)"
CLOUDFLARE_TUNNEL_ID="$(_cf_get CLOUDFLARE_TUNNEL_ID)"

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN fehlt in .env}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID fehlt in .env}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID fehlt in .env}"
: "${CLOUDFLARE_TUNNEL_ID:?CLOUDFLARE_TUNNEL_ID fehlt in .env}"

CF_API="https://api.cloudflare.com/client/v4"
TUNNEL_CNAME="${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com"
AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

# cf_call <method> <path> [json_body]  → body to stdout, exit on error
cf_call() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -w '\n%{http_code}' -X "$method"
              -H "$AUTH_HEADER" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(-d "$body")
  local raw http_code resp_body
  raw="$(curl "${args[@]}" "${CF_API}${path}")"
  http_code="${raw##*$'\n'}"
  resp_body="${raw%$'\n'*}"
  if (( http_code < 200 || http_code >= 300 )); then
    err "CF API $method $path → HTTP $http_code: $resp_body"
  fi
  if [[ "$(echo "$resp_body" | jq -r '.success // false')" != "true" ]]; then
    err "CF API $method $path → success=false: $(echo "$resp_body" | jq -c '.errors // .')"
  fi
  echo "$resp_body"
}

# ============================================================================
# Step 1: Tunnel-Ingress reconcilen
# ============================================================================
log "Tunnel-Ingress reconcilen"

CURRENT_CFG="$(cf_call GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/configurations")"
# Reduce auf {hostname, service} damit Extra-Felder (originRequest etc.)
# das Diff nicht stören.
CURRENT_NORM="$(echo "$CURRENT_CFG" | jq -c '[.result.config.ingress[]? | {hostname, service}]')"
DESIRED_NORM="$(jq -c '[(.routes[] | {hostname, service}), {hostname: null, service: "http_status:404"}]' "$ROUTES_JSON")"

if [[ "$CURRENT_NORM" == "$DESIRED_NORM" ]]; then
  ok "Ingress bereits aktuell ($(jq '.routes | length' "$ROUTES_JSON") Hostnames + catch-all)"
else
  echo "  Aktuell:"
  echo "$CURRENT_NORM" | jq -r '.[] | "    \(.hostname // "*") → \(.service)"'
  echo "  Gewollt:"
  echo "$DESIRED_NORM" | jq -r '.[] | "    \(.hostname // "*") → \(.service)"'
  PUT_BODY="$(jq -nc --argjson ingress "$DESIRED_NORM" '{config: {ingress: $ingress}}')"
  cf_call PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${CLOUDFLARE_TUNNEL_ID}/configurations" "$PUT_BODY" >/dev/null
  ok "Ingress aktualisiert"
fi

# ============================================================================
# Step 2: DNS-CNAMEs reconcilen
# ============================================================================
log "DNS-CNAMEs reconcilen ($(jq '.routes | length' "$ROUTES_JSON") Hostnames → $TUNNEL_CNAME)"

CREATED=0
UPDATED=0
UNCHANGED=0

while IFS= read -r HOSTNAME; do
  EXISTING="$(cf_call GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}")"
  COUNT="$(echo "$EXISTING" | jq '.result | length')"

  REC_BODY="$(jq -nc --arg n "$HOSTNAME" --arg c "$TUNNEL_CNAME" \
    '{type: "CNAME", name: $n, content: $c, ttl: 1, proxied: true}')"

  if (( COUNT == 0 )); then
    cf_call POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "$REC_BODY" >/dev/null
    ok "  + $HOSTNAME"
    CREATED=$((CREATED + 1))
  else
    REC_ID="$(echo "$EXISTING"     | jq -r '.result[0].id')"
    REC_CONTENT="$(echo "$EXISTING" | jq -r '.result[0].content')"
    REC_PROXIED="$(echo "$EXISTING" | jq -r '.result[0].proxied')"
    if [[ "$REC_CONTENT" == "$TUNNEL_CNAME" && "$REC_PROXIED" == "true" ]]; then
      UNCHANGED=$((UNCHANGED + 1))
    else
      cf_call PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${REC_ID}" "$REC_BODY" >/dev/null
      ok "  ↻ $HOSTNAME  (war: $REC_CONTENT, proxied=$REC_PROXIED)"
      UPDATED=$((UPDATED + 1))
    fi
  fi
done < <(jq -r '.routes[].hostname' "$ROUTES_JSON")

echo
ok "DNS-Records: $CREATED neu · $UPDATED aktualisiert · $UNCHANGED unverändert"

# ============================================================================
# Step 3: Orphan Tunnel-CNAMEs aufräumen
# (CNAMEs die auf unseren Tunnel zeigen, aber NICHT in routes.json stehen)
# DKIM, MX, A, AAAA, andere CNAMEs bleiben unangetastet.
# ============================================================================
log "Orphan Tunnel-CNAMEs aufräumen"

ALL_CNAMES="$(cf_call GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&per_page=100")"
DESIRED_HOSTS="$(jq -r '.routes[].hostname' "$ROUTES_JSON" | sort -u)"

DELETED=0
while IFS=$'\t' read -r REC_ID REC_NAME REC_CONTENT; do
  # Nur CNAMEs die EXAKT auf unseren Tunnel zeigen → andere bleiben in Ruhe
  [[ "$REC_CONTENT" == "$TUNNEL_CNAME" ]] || continue
  # In routes.json enthalten? → behalten
  if echo "$DESIRED_HOSTS" | grep -Fxq -- "$REC_NAME"; then
    continue
  fi
  cf_call DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${REC_ID}" >/dev/null
  ok "  - $REC_NAME  (zeigte auf $TUNNEL_CNAME)"
  DELETED=$((DELETED + 1))
done < <(echo "$ALL_CNAMES" | jq -r '.result[] | "\(.id)\t\(.name)\t\(.content)"')

if (( DELETED == 0 )); then
  ok "Keine orphan Tunnel-CNAMEs gefunden"
else
  ok "$DELETED orphan CNAME(s) gelöscht"
fi

log "✓ Cloudflare reconcile abgeschlossen"
