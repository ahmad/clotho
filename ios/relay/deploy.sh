#!/bin/bash
# Deploys the push relay Worker (`npm run deploy`, or ios/relay/deploy.sh). The Apple team ID and the APNs
# key ID aren't in wrangler.toml: they come from the environment, CLOTHO_TEAM_ID and CLOTHO_APNS_KEY_ID, which
# on the dev box are in ~/.config/clotho/local.env (CLOTHO_LOCAL_ENV overrides the path). The account comes from
# the wrangler login, or CLOUDFLARE_ACCOUNT_ID. Arguments go on to `wrangler deploy`, e.g. --dry-run.
set -euo pipefail
local_env=${CLOTHO_LOCAL_ENV:-$HOME/.config/clotho/local.env}
# shellcheck disable=SC1090
[ -r "$local_env" ] && . "$local_env"
missing=
for v in CLOTHO_TEAM_ID CLOTHO_APNS_KEY_ID; do [ -n "${!v:-}" ] || missing+=" $v"; done
if [ -n "$missing" ]; then
  echo "relay deploy: set$missing (in $local_env or the environment); nothing deployed" >&2
  exit 2
fi
cd "$(dirname "$0")"
exec npx wrangler@4 deploy --var "APNS_TEAM_ID:$CLOTHO_TEAM_ID" --var "APNS_KEY_ID:$CLOTHO_APNS_KEY_ID" "$@"
