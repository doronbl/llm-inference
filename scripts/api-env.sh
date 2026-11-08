#!/usr/bin/env bash
# Prints shell exports for calling the API by hand: API (base URL), TOKEN (a
# fresh Cognito access token, valid for 60 minutes) and MODEL.
#
#   eval "$(scripts/api-env.sh)"
#   curl -s "$API/models" -H "Authorization: Bearer $TOKEN"
#
# Runs in its own process, so the strict shell options of lib.sh stay out of
# your interactive shell. Run it again when the token expires.
source "$(dirname "$0")/lib.sh"
require terraform curl jq

api="$(tf_deploy '.api_url')"
token="$(access_token)"
[[ -n "${token}" && "${token}" != "null" ]] || die "could not get a Cognito access token"
model="$(curl --silent --show-error --fail "${api}/models" -H "Authorization: Bearer ${token}" | jq -r '.data[0].id')"

printf 'export API=%q\nexport TOKEN=%q\nexport MODEL=%q\n' "${api}" "${token}" "${model}"
