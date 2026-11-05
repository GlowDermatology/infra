#!/usr/bin/env bash
# Smoke test of a running environment. Exit 0 = healthy. Run by deploy.sh, safe to run any time:
#
#   scripts/healthcheck.sh <staging|production>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"

site="$(stack_value SITE_DOMAIN)"
failures=0
ok() { printf '    ok    %s\n' "$*"; }
fail() {
	printf '    FAIL  %s\n' "$*"
	failures=$((failures + 1))
}

log "Containers"
# A Vault agent that has nothing rendered yet means Vault is sealed or unreachable, not a broken release.
for agent in vault-agent-backend vault-agent-frontend vault-agent-datastores; do
	state="$(docker inspect -f '{{.State.Health.Status}}' "glowderma-$ENV-$agent-1" 2>/dev/null || echo missing)"
	if [ "$state" = healthy ]; then ok "$agent"; else fail "$agent is $state: Vault sealed or unreachable? scripts/vault/unseal.sh $ENV"; fi
done
for service in postgres redis backend-api backend-worker frontend edge; do
	state="$(docker inspect -f '{{.State.Health.Status}}' "glowderma-$ENV-$service-1" 2>/dev/null || echo missing)"
	if [ "$state" = healthy ]; then ok "$service"; else fail "$service is $state"; fi
done
if [ "$(docker inspect -f '{{.State.Running}}' "glowderma-$ENV-backend-beat-1" 2>/dev/null)" = true ]; then
	ok "backend-beat running"
else fail "backend-beat is not running"; fi

log "Inside the stack"
if app_compose exec -T backend-api python -c "
import urllib.request as u
u.urlopen(u.Request('http://127.0.0.1:8000/api/v1/health/?ready=1', headers={'Host': 'localhost'}), timeout=10)
" >/dev/null 2>&1; then ok "Django readiness (database, cache, broker)"; else fail "Django /api/v1/health/?ready=1"; fi

# The Next server -> Django hop with the internal secret: proves the network, ALLOWED_HOSTS, the admin network
# gate and that both sides hold the same INTERNAL_API_SECRET (401 = gate passed, no staff session).
hop="$(app_compose exec -T frontend node -e "
const s = JSON.parse(require('fs').readFileSync('/run/secrets/frontend.json', 'utf8'));
fetch('http://172.30.0.30:8000/api/v1/admin/auth/me/', {headers: {'X-GD-Internal-Secret': s.GLOWDERMA_INTERNAL_SECRET}})
  .then(r => console.log(r.status), () => console.log('unreachable'));
" 2>/dev/null || echo error)"
case "$hop" in
401) ok "Next -> Django admin API hop (gate and internal secret)" ;;
403) fail "Next -> Django answered 403: ADMIN_API_ALLOWED_NETS or INTERNAL_API_SECRET mismatch" ;;
*) fail "Next -> Django admin API hop: $hop" ;;
esac

log "Through the edge (https://$site)"
curl_edge() { curl -sS -o /dev/null --max-time 15 --resolve "$site:443:127.0.0.1" "$@"; }
tls="--fail"
if ! curl_edge "https://$site/healthz" 2>/dev/null; then
	note "TLS for $site does not verify yet (first certificate pending? DNS?); continuing without verification"
	tls="--insecure"
fi
code="$(curl_edge $tls -w '%{http_code}' "https://$site/healthz" || true)"
[ "$code" = 200 ] && ok "Next.js /healthz" || fail "Next.js /healthz answered $code"
code="$(curl_edge $tls -w '%{http_code}' "https://$site/api/v1/health/" || true)"
[ "$code" = 200 ] && ok "Django /api/v1/health/ (same origin)" || fail "Django /api/v1/health/ answered $code"
for path in /api/v1/admin/auth/me/ /api/v1/docs/ /api/v1/schema/ /django-admin/; do
	code="$(curl_edge --insecure -w '%{http_code}' "https://$site$path" || true)"
	[ "$code" = 404 ] && ok "$path hidden (404)" || fail "$path answered $code, expected 404"
done
altsvc="$(curl -sS -D - -o /dev/null --max-time 15 --insecure --resolve "$site:443:127.0.0.1" "https://$site/healthz" | tr -d '\r' | sed -n 's/^alt-svc: //Ip')"
case "$altsvc" in *h3=*) ok "HTTP/3 advertised ($altsvc)" ;; *) fail "no HTTP/3 Alt-Svc header" ;; esac

if [ "$failures" -gt 0 ]; then
	echo
	app_compose ps -a
	die "$failures health check(s) failed"
fi
log "All health checks passed"
