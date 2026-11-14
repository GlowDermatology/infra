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
# shellcheck source=lib.sh
. scripts/lib.sh
for env in staging production; do
	d="environments/$env"
	# MEDIA_BACKEND is computed by lib.sh (app_compose) in real use; compute it the same way here.
	MEDIA_BACKEND="$(ENV_DIR="$d" media_backend)"
	VAULT_AGENT_CONFIG_HASH="$(agent_config_hash)"
	export MEDIA_BACKEND VAULT_AGENT_CONFIG_HASH
	# Three renders: the default stack, with the optional object storage, and with every profile (tools too).
	for variant in base os os-tools; do
		case "$variant" in
		base) profiles=() ;;
		os) profiles=(--profile object-storage) ;;
		os-tools) profiles=(--profile tools --profile object-storage --profile object-storage-tools) ;;
		esac
		RUNTIME_DIR=/opt/glowderma/runtime docker compose -f compose/app.yaml --env-file "$d/stack.env" \
			--env-file "$d/backend/image.env" --env-file "$d/frontend/image.env" --env-file "$work/images.env" \
			--env-file "$work/local.env" "${profiles[@]}" config --format json >"$work/app-$env-$variant.json" ||
			fail "compose/app.yaml ($env, $variant)"
	done
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
    # stack.env values the object storage rules compare against.
    stack = {}
    for line in Path(f"environments/{env}/stack.env").read_text().splitlines():
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            stack[k] = v
    for key in ("OBJECT_STORAGE_ENABLED", "USE_S3"):
        if stack.get(key) not in ("true", "false"):
            err(f"{env}: {key} in stack.env must be true or false")
    if not stack.get("S3_LOCATION"):
        err(f"{env}: S3_LOCATION in stack.env must not be empty")
    try:
        base = json.loads((work / f"app-{env}-base.json").read_text())
        with_os = json.loads((work / f"app-{env}-os.json").read_text())
        # Every service of every profile goes through the generic rules below.
        app = json.loads((work / f"app-{env}-os-tools.json").read_text())
    except json.JSONDecodeError:
        err(f"{env}: compose/app.yaml did not render (see the compose error above); structural rules skipped")
        continue
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
    # ---- Optional object storage (SeaweedFS). Vault-dependent consistency rules live in scripts/deploy.sh.
    for name in ("object-storage", "object-storage-init"):
        if name in base["services"]:
            err(f"{env}: {name} is in the default render; it must be behind its profile")
    if "object-storage-init" in with_os["services"]:
        err(f"{env}: object-storage-init must be behind the object-storage-tools profile, never started by up")
    missing = [n for n in ("object-storage", "object-storage-init") if n not in app["services"]]
    if missing:
        err(f"{env}: services missing from the render with the object-storage profiles: {missing}")
    else:
        store = app["services"]["object-storage"]
        init = app["services"]["object-storage-init"]
        store_ip = (store.get("networks", {}).get("front") or {}).get("ipv4_address")
        if "back" not in store.get("networks", {}):
            err(f"{env}/object-storage: must be on the 'back' network (the backend and the init reach it there by service name)")
        seeded = Path("scripts/vault/generate-app-secrets.sh").read_text()
        seeded_url = re.search(r'"S3_ENDPOINT_URL":"([^"]*)"', seeded)
        seeded_bucket = re.search(r'"S3_BUCKET_NAME":"([^"]+)"', seeded)
        edge_env_os = app["services"]["edge"]["environment"]
        upstream = edge_env_os.get("OBJECT_STORAGE_UPSTREAM", "")
        addresses = {
            "object-storage ipv4_address": store_ip,
            "edge OBJECT_STORAGE_UPSTREAM": upstream.rsplit(":", 1)[0] if upstream else None,
        }
        if len(set(addresses.values())) != 1 or None in addresses.values():
            err(f"{env}: the edge upstream address differs from the object-storage ipv4_address: {addresses}")
        if not seeded_url or seeded_url.group(1) != "http://object-storage:8333":
            err(f"{env}: seeded S3_ENDPOINT_URL in scripts/vault/generate-app-secrets.sh must be exactly http://object-storage:8333")
        if "back" not in init.get("networks", {}):
            err(f"{env}/object-storage-init: must be on the 'back' network (it reaches the storage by service name)")
        if upstream and not upstream.endswith(":8333"):
            err(f"{env}: edge OBJECT_STORAGE_UPSTREAM must point at the S3 port 8333")
        buckets = {
            "edge OBJECT_STORAGE_BUCKET": edge_env_os.get("OBJECT_STORAGE_BUCKET"),
            "object-storage-init OBJECT_STORAGE_BUCKET": init.get("environment", {}).get("OBJECT_STORAGE_BUCKET"),
            "seeded S3_BUCKET_NAME (scripts/vault/generate-app-secrets.sh)": seeded_bucket and seeded_bucket.group(1),
        }
        if len(set(buckets.values())) != 1 or None in buckets.values():
            err(f"{env}: the bucket name differs between: {buckets}")
        # Only the S3 gateway may listen off-container: master, volume and filer have no authentication.
        command = store.get("command") or []
        for flag in ("-ip=127.0.0.1", "-ip.bind=127.0.0.1", "-s3.ip.bind=0.0.0.0", "-s3.port.iceberg=0", "-s3.port.lance=0"):
            if flag not in command:
                err(f"{env}/object-storage: command must contain {flag} (only the S3 gateway is reachable)")
        if any(arg.startswith(("-ip.bind=0", "-ip=0", "-filer.ip", "-master.ip", "-volume.ip")) for arg in command):
            err(f"{env}/object-storage: master, volume and filer must stay on 127.0.0.1")
        # Their secrets volume holds the object storage's files only, never the database passwords.
        for name in ("object-storage", "object-storage-init"):
            sources = {str(v.get("source", "")) for v in app["services"][name].get("volumes") or []}
            if "datastores-secrets" in sources or "object-storage-secrets" not in sources:
                err(f"{env}/{name}: must mount object-storage-secrets, never datastores-secrets")
        for name in ("backend-api", "backend-worker", "backend-migrate", "backend-beat"):
            dep = (app["services"][name].get("depends_on") or {}).get("object-storage")
            if not dep or dep.get("required") is not False or dep.get("condition") != "service_healthy":
                err(f"{env}/{name}: must depend on object-storage (service_healthy, required: false)")
    for service in ("edge", "backend-api", "backend-worker", "backend-migrate", "backend-beat"):
        senv = app["services"][service]["environment"]
        if senv.get("S3_LOCATION") != stack.get("S3_LOCATION"):
            err(f"{env}/{service}: S3_LOCATION does not match stack.env")
        if service != "edge" and senv.get("USE_S3") != stack.get("USE_S3"):
            err(f"{env}/{service}: USE_S3 does not match stack.env")
    wanted = "object-storage" if stack.get("OBJECT_STORAGE_ENABLED") == stack.get("USE_S3") == "true" else "disk"
    if app["services"]["edge"]["environment"].get("MEDIA_BACKEND") != wanted:
        err(f"{env}/edge: MEDIA_BACKEND must be {wanted} for OBJECT_STORAGE_ENABLED/USE_S3 in stack.env")
    # Agents are recreated when vault/agent/ changes (scripts/lib.sh agent_config_hash).
    for name, svc in app["services"].items():
        if name.startswith("vault-agent") and not (svc.get("labels") or {}).get("org.glowderma.agent-config"):
            err(f"{env}/{name}: the org.glowderma.agent-config label is missing")
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

if len(names) == 2 and names["staging"] == names["production"]:
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
