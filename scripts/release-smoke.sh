#!/usr/bin/env bash
# Boot the image against an isolated, disposable PostgreSQL 17 database.
set -euo pipefail
image=${1:-ravix-elixir-check}
name="ravix-smoke-$$"
cleanup() {
  docker rm -f "${name}-app" "${name}-db" >/dev/null 2>&1 || true
  docker network rm "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$name" >/dev/null
docker run -d --name "${name}-db" --network "$name" \
  --tmpfs /var/lib/postgresql/data -e POSTGRES_PASSWORD=smoke-only \
  -e POSTGRES_DB=ravix postgres:17 >/dev/null
for i in $(seq 1 30); do
  if docker exec "${name}-db" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
# A pre-existing Bun table must survive the Elixir migration unchanged.
docker exec "${name}-db" psql -U postgres -d ravix -c \
  "CREATE TABLE public.users (legacy_marker text); INSERT INTO public.users VALUES ('preserved');" >/dev/null
args=(--network "$name" -e "DATABASE_URL=postgres://postgres:smoke-only@${name}-db:5432/ravix" \
  -e RAVIX_SECRET=local-release-smoke-only -e PUBLIC_URL=http://localhost:4000 -e PORT=4000)
docker run --rm "${args[@]}" "$image" /app/bin/migrate
# Re-running migrations must be harmless.
docker run --rm "${args[@]}" "$image" /app/bin/migrate
legacy=$(docker exec "${name}-db" psql -U postgres -d ravix -Atc "SELECT legacy_marker FROM public.users")
test "$legacy" = preserved
docker run -d --name "${name}-app" "${args[@]}" -p 127.0.0.1::4000 "$image" >/dev/null
address=$(docker port "${name}-app" 4000/tcp)
for i in $(seq 1 30); do
  if curl -fsS "http://${address}/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "http://${address}/healthz"
# Readiness, separately: this is what Render's health check reads and so what
# decides whether an instance takes traffic (ADR 0003). It answers only when the
# database does, which is the half /healthz deliberately cannot test.
curl -fsS "http://${address}/readyz"
# `/` has nothing to show a browser with no session, so it redirects; following
# it is the check, since a release that renders the shell but cannot route a
# stranger to sign-in is not serving anybody.
curl -fsSL "http://${address}/" | grep -F 'Sign in to Ravix' >/dev/null
curl -fsS "http://${address}/theme.js" | grep -F 'ravix.theme' >/dev/null
curl -fsS "http://${address}/assets/js/app.js" >/dev/null
curl -fsS "http://${address}/fonts/IBMPlexSans-Regular.woff2" >/dev/null
curl -fsS "http://${address}/fonts/IBMPlexMono-Regular.woff2" >/dev/null
printf 'Release boot, readiness, sign-in page, fonts, assets, idempotent migrations, and legacy table preservation passed.\n'
