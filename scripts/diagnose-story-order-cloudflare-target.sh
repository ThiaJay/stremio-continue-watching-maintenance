#!/usr/bin/env bash
set -euo pipefail

test -n "${CLOUDFLARE_API_TOKEN:-}"
test -n "${CLOUDFLARE_ACCOUNT_ID:-}"
test -n "${SCRIPT_NAME:-}"

auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
account="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID"
subdomain_json="$(curl -fsS "${auth[@]}" "$account/workers/subdomain")"
subdomain="$(node -e 'const x=JSON.parse(process.argv[1]);if(!x.success||!x.result?.subdomain)process.exit(2);process.stdout.write(String(x.result.subdomain))' "$subdomain_json")"

cb="$(date +%s)"
account_host="https://$SCRIPT_NAME.$subdomain.workers.dev"
public_host="https://stremio-story-order.storyorder.workers.dev"

account_version="$(curl -fsS -H 'Cache-Control: no-cache' "$account_host/manifest.json?cb=$cb" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).version||''))")"
public_version="$(curl -fsS -H 'Cache-Control: no-cache' "$public_host/manifest.json?cb=$cb" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(JSON.parse(s).version||''))")"

echo "account_subdomain=$subdomain"
echo "account_host_version=$account_version"
echo "public_host_version=$public_version"
