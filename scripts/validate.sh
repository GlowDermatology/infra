#!/usr/bin/env bash
# Static validation of this repository (CI: .github/workflows/validate.yaml; run it locally before a PR).
# Needs docker (the CLI only: `compose config` works without a daemon) and python3. Optional tools are used
# when present: CADDY_BIN (caddy validate + edge probe), shellcheck.
#
#   scripts/validate.sh
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() {
	echo "FAIL  $*"
	failures=$((failures + 1))
}

# Fake image pins so the files resolve before the first release exists.
cat >"$work/images.env" <<'EOF'
BACKEND_TAG=backend-0000000
BACKEND_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
FRONTEND_TAG=frontend-0000000-env
FRONTEND_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
EOF
printf 'OPS_ALLOWED_IPS=192.0.2.10/32 198.51.100.0/24\n' >"$work/local.env"

echo "==> Compose files resolve for both environments"
for env in staging production; do
	d="environments/$env"
	RUNTIME_DIR=/opt/glowderma/runtime docker compose -f compose/app.yaml --env-file "$d/stack.env" \
		--env-file "$d/backend/image.env" --env-file "$d/frontend/image.env" --env-file "$work/images.env" \
		--env-file "$work/local.env" config --format json >"$work/app-$env.json" || fail "compose/app.yaml ($env)"
	docker compose -f compose/vault.yaml --env-file "$d/stack.env" config --format json >"$work/vault-$env.json" ||
		fail "compose/vault.yaml ($env)"
	# An unpublished image must be refused, never silently replaced by a mutable tag.
	if docker compose -f compose/app.yaml --env-file "$d/stack.env" --env-file "$d/backend/image.env" \
		--env-file "$d/frontend/image.env" config --quiet 2>/dev/null; then
		grep -q '_DIGEST=$' "$d/backend/image.env" "$d/frontend/image.env" &&
			fail "$env: compose accepted an image.env without a digest"
	fi
done

echo "==> Structural rules"
python3 - "$work" <<'PY' || failures=$((failures + 1))
import json, re, sys
from pathlib import Path

work = Path(sys.argv[1])
errors = []
def err(msg): errors.append(msg)

names = {}
for env in ("staging", "production"):
    app = json.loads((work / f"app-{env}.json").read_text())
    vault = json.loads((work / f"vault-{env}.json").read_text())
    names[env] = (app["name"], vault["name"])
    if app["name"] != f"glowderma-{env}" or vault["name"] != f"glowderma-{env}-vault":
        err(f"{env}: unexpected project names {app['name']!r} / {vault['name']!r}")
    services = {**app["services"], **{f"vault:{k}": v for k, v in vault["services"].items()}}
    for name, svc in services.items():
        image = svc.get("image", "")
        if "@sha256:" not in image:
            err(f"{env}/{name}: image {image!r} is not pinned by digest")
        if not svc.get("read_only"):
            err(f"{env}/{name}: read_only is not set")
        if svc.get("cap_drop") != ["ALL"]:
            err(f"{env}/{name}: cap_drop must be [ALL]")
        if "no-new-privileges:true" not in (svc.get("security_opt") or []):
            err(f"{env}/{name}: no-new-privileges missing")
        if svc.get("privileged") or svc.get("cap_add"):
            err(f"{env}/{name}: privileged/cap_add is not allowed")
        user = str(svc.get("user", ""))
        if not user or user.split(":")[0] in ("0", "root"):
            err(f"{env}/{name}: must run as an explicit non-root user (got {user!r})")
        for volume in svc.get("volumes") or []:
            if "docker.sock" in str(volume.get("source", "")):
                err(f"{env}/{name}: the Docker socket must never be mounted")
        if svc.get("ports") and name != "edge":
            err(f"{env}/{name}: only the edge may publish ports")
    edge_ports = sorted((p["target"], p["protocol"]) for p in app["services"]["edge"]["ports"])
    if edge_ports != [(80, "tcp"), (443, "tcp"), (443, "udp")]:
        err(f"{env}: edge must publish exactly 80/tcp, 443/tcp, 443/udp (got {edge_ports})")
    for name in ("postgres", "redis"):
        if set(app["services"][name]["networks"]) != {"back"}:
            err(f"{env}/{name}: must be on the internal 'back' network only")
    if not app["networks"]["back"].get("internal"):
        err(f"{env}: network 'back' must be internal")
    # Fixed addresses and the Django/gunicorn gates that name them must agree.
    nets = {n: s["networks"] for n, s in app["services"].items()}
    edge_ip = nets["edge"]["front"]["ipv4_address"]
    next_ip = nets["frontend"]["front"]["ipv4_address"]
    api_ip = nets["backend-api"]["front"]["ipv4_address"]
    env_api = app["services"]["backend-api"]["environment"]
    expect = {
        "TRUSTED_PROXIES": f"{edge_ip}/32",
        "FORWARDED_ALLOW_IPS": edge_ip,
        "ADMIN_API_ALLOWED_NETS": f"{next_ip}/32",
    }
    for key, value in expect.items():
        if env_api.get(key) != value:
            err(f"{env}: backend {key}={env_api.get(key)!r}, expected {value!r} (fixed addresses in compose)")
    if api_ip not in env_api.get("ALLOWED_HOSTS", "").split(","):
        err(f"{env}: ALLOWED_HOSTS must contain the API address the Next server calls ({api_ip})")
    if app["services"]["frontend"]["environment"].get("GLOWDERMA_API_URL") != f"http://{api_ip}:8000":
        err(f"{env}: GLOWDERMA_API_URL must be http://{api_ip}:8000")
    edge_env = app["services"]["edge"]["environment"]
    if edge_env.get("API_UPSTREAM") != f"{api_ip}:8000" or edge_env.get("FRONTEND_UPSTREAM") != f"{next_ip}:3000":
        err(f"{env}: edge upstreams do not match the fixed addresses")
    ops = edge_env.get("OPS_ALLOWED_IPS", "")
    if "," in ops:
        err(f"{env}: OPS_ALLOWED_IPS must be space separated (Caddy and Django both split on spaces)")
    # No application container may receive a Vault token or AppRole credentials.
    for name, svc in app["services"].items():
        if name.startswith("vault-agent"):
            continue
        for key in (svc.get("environment") or {}):
            if key.startswith("VAULT_"):
                err(f"{env}/{name}: Vault variable {key} given to an application container")
        for volume in svc.get("volumes") or []:
            if "approle" in str(volume.get("source", "")):
                err(f"{env}/{name}: AppRole material mounted into an application container")

if names["staging"] == names["production"]:
    err("staging and production must have different project names")

# Env files are public: nothing that looks like a secret value.
secretish = re.compile(r"^[A-Z0-9_]*(PASSWORD|SECRET|TOKEN|_KEY|PRIVATE)[A-Z0-9_]*=(.+)$")
for path in Path("environments").rglob("*.env"):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = secretish.match(line.strip())
        if match and match.group(2).strip():
            err(f"{path}:{number}: looks like a secret value; secrets belong in Vault")
# image.env: only the expected keys, digests well-formed when set.
for path in Path("environments").glob("*/*/image.env"):
    app = path.parent.name.upper()
    keys = {}
    for line in path.read_text().splitlines():
        if line and not line.startswith("#"):
            k, _, v = line.partition("=")
            keys[k] = v
    if set(keys) != {f"{app}_{k}" for k in ("IMAGE", "TAG", "DIGEST", "SOURCE_SHA", "BUILT_AT")}:
        err(f"{path}: unexpected keys {sorted(keys)}")
    digest = keys.get(f"{app}_DIGEST", "")
    if digest and not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        err(f"{path}: malformed digest {digest!r}")
    if keys.get(f"{app}_TAG", "") in ("latest",):
        err(f"{path}: mutable tag")

for e in errors:
    print("FAIL ", e)
if errors:
    sys.exit(1)
print("ok    structural rules")
PY

echo "==> Vault policies only grant read on their own environment"
for env in staging production; do
	other=$([ "$env" = staging ] && echo production || echo staging)
	grep -q "secret/data/$other/" vault/policies/"$env"/*.hcl && fail "vault/policies/$env references $other"
	grep -hE 'capabilities' vault/policies/"$env"/*.hcl | grep -vq '\["read"\]' && fail "vault/policies/$env grants more than read"
	grep -qE 'path "secret/(\*|data/\*)' vault/policies/"$env"/*.hcl && fail "vault/policies/$env grants a wildcard"
done
grep -q 'tls_skip_verify' -r vault/ && fail "tls_skip_verify must never appear"

echo "==> Caddy"
if [ -n "${CADDY_BIN:-}" ]; then
	ACME_EMAIL=ci@example.com SITE_DOMAIN=example.com OPS_DOMAIN=ops.example.com \
		OPS_ALLOWED_IPS="192.0.2.10/32 198.51.100.0/24" "$CADDY_BIN" validate --config caddy/Caddyfile \
		--adapter caddyfile >/dev/null 2>&1 || fail "caddy validate"
	python3 -I caddy/edge_probe.py --caddy "$CADDY_BIN" || fail "edge probe"
else
	echo "skip  (set CADDY_BIN)"
fi

echo "==> Shell scripts"
if command -v shellcheck >/dev/null; then
	shellcheck -x -S warning scripts/*.sh scripts/vault/*.sh scripts/ci/*.sh postgres/initdb/*.sh || fail "shellcheck"
else
	echo "skip  (shellcheck not installed)"
fi
for script in scripts/*.sh scripts/vault/*.sh scripts/ci/*.sh postgres/initdb/*.sh; do
	[ -x "$script" ] || fail "$script is not executable"
done
if grep -rnE 'compose[^#]*\bdown\b[^#]*-v|volume (rm|prune)' scripts/ | grep -v '^scripts/validate.sh'; then
	fail "a script removes volumes"
fi

echo
[ "$failures" -eq 0 ] || {
	echo "$failures validation failure(s)"
	exit 1
}
echo "Validation passed"
