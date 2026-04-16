#!/usr/bin/env bash

lapits_request_builder() {
  local choice request_json response_json curl_cmd

  while true; do
    clear
    gum style --border rounded --padding "1 2" "Request Builder"

    choice=$(gum choose \
      "Create New Request" \
      "Import from cURL" \
      "Back")

    case "$choice" in
      "Create New Request")
        request_json="$(lapits_build_request_interactively)"
        lapits_request_actions "$request_json"
        ;;
      "Import from cURL")
        local raw_curl
        raw_curl="$(gum write --placeholder "Paste full curl command here")"
        [ -z "$raw_curl" ] && continue
        request_json="$(lapits_curl_import_to_request "$raw_curl")"
        lapits_request_actions "$request_json"
        ;;
      "Back")
        return 0
        ;;
    esac
  done
}

lapits_request_actions() {
  local request_json="${1:?request json required}"
  local choice response_json curl_cmd

  while true; do
    clear
    lapits_show_request_summary "$request_json"

    choice=$(gum choose \
      "Run Request" \
      "Export as cURL" \
      "Edit Request" \
      "Back")

    case "$choice" in
      "Run Request")
        response_json="$(lapits_execute_request "$request_json")"
        lapits_render_response "$response_json"
        ;;
      "Export as cURL")
        curl_cmd="$(lapits_request_to_curl "$(lapits_apply_auth "$(lapits_interpolate_json "$request_json")")")"
        clear
        gum style --border rounded --padding "1 2" "Exported cURL"
        echo "$curl_cmd"
        echo
        gum input --placeholder "Press Enter to continue..." >/dev/null
        ;;
      "Edit Request")
        request_json="$(lapits_build_request_interactively "$request_json")"
        ;;
      "Back")
        return 0
        ;;
    esac
  done
}

lapits_build_request_interactively() {
  local existing_json="${1:-}"
  local name method url headers_text query_text body_type body auth_type auth_json
  local headers_json query_json

  if [ -n "$existing_json" ]; then
    name="$(jq -r '.name // ""' <<<"$existing_json")"
    method="$(jq -r '.method // "GET"' <<<"$existing_json")"
    url="$(jq -r '.url // ""' <<<"$existing_json")"
    body_type="$(jq -r '.body_type // "none"' <<<"$existing_json")"
    body="$(jq -r '.body // ""' <<<"$existing_json")"
    headers_text="$(jq -r '.headers // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$existing_json")"
    query_text="$(jq -r '.query // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$existing_json")"
  else
    name=""
    method="GET"
    url=""
    body_type="none"
    body=""
    headers_text=""
    query_text=""
  fi

  clear
  gum style --border rounded --padding "1 2" "Create / Edit Request"

  name="$(printf '%s' "$name" | gum input --value "$name" --placeholder "Request name")"

  method="$(printf '%s\n' GET POST PUT PATCH DELETE OPTIONS HEAD | gum choose --selected "$method" || true)"
  method="${method:-GET}"

  url="$(gum input --value "$url" --placeholder "URL (supports {{variables}})")"

  headers_text="$(printf '%s\n' "$headers_text" | gum write --placeholder $'Headers, one per line\nExample:\nAccept=application/json\nX-Trace-Id=123')"
  headers_json="$(lapits_kv_text_to_json "$headers_text")"

  query_text="$(printf '%s\n' "$query_text" | gum write --placeholder $'Query params, one per line\nExample:\npage=1\nlimit=10')"
  query_json="$(lapits_kv_text_to_json "$query_text")"

  body_type="$(printf '%s\n' none json form-data x-www-form-urlencoded raw binary | gum choose)"

  case "$body_type" in
    "none")
      body=""
      ;;
    "json")
      body="$(gum write --value "$body" --placeholder $'{\n  "hello": "world"\n}')"
      ;;
    "x-www-form-urlencoded")
      body="$(gum write --value "$body" --placeholder $'username=jogo&password=secret')"
      ;;
    "form-data")
      body="$(gum write --value "$body" --placeholder $'name=Jogo\nfile=@/absolute/path/to/file.png')"
      ;;
    "raw")
      body="$(gum write --value "$body" --placeholder "Raw body text")"
      ;;
    "binary")
      body="$(gum input --value "$body" --placeholder "@/absolute/path/to/file.bin")"
      ;;
  esac

  auth_type="$(printf '%s\n' none bearer basic api_key oauth2 | gum choose)"

  case "$auth_type" in
    "none")
      auth_json='{"type":"none"}'
      ;;
    "bearer")
      local bearer_token
      bearer_token="$(gum input --placeholder "Bearer token (supports {{variables}})")"
      auth_json="$(jq -cn --arg token "$bearer_token" '{type:"bearer", token:$token}')"
      ;;
    "basic")
      local username password
      username="$(gum input --placeholder "Username")"
      password="$(gum input --password --placeholder "Password")"
      auth_json="$(jq -cn --arg username "$username" --arg password "$password" '{type:"basic", username:$username, password:$password}')"
      ;;
    "api_key")
      local api_key_name api_key_value api_key_in
      api_key_name="$(gum input --placeholder "Key name (e.g. X-API-Key)")"
      api_key_value="$(gum input --placeholder "Key value (supports {{variables}})")"
      api_key_in="$(printf '%s\n' header query | gum choose)"
      auth_json="$(jq -cn --arg key "$api_key_name" --arg value "$api_key_value" --arg in "$api_key_in" '{type:"api_key", key:$key, value:$value, in:$in}')"
      ;;
    "oauth2")
      local access_token
      access_token="$(gum input --placeholder "Access token (supports {{variables}})")"
      auth_json="$(jq -cn --arg access_token "$access_token" '{type:"oauth2", access_token:$access_token}')"
      ;;
  esac

  jq -cn \
    --arg name "$name" \
    --arg method "$method" \
    --arg url "$url" \
    --arg body_type "$body_type" \
    --arg body "$body" \
    --argjson headers "$headers_json" \
    --argjson query "$query_json" \
    --argjson auth "$auth_json" \
    '{
      name: $name,
      method: $method,
      url: $url,
      headers: $headers,
      query: $query,
      body_type: $body_type,
      body: $body,
      auth: $auth
    }'
}

lapits_show_request_summary() {
  local request_json="${1:?request json required}"
  local resolved_json

  resolved_json="$(lapits_apply_auth "$(lapits_interpolate_json "$request_json")")"

  gum style --border rounded --padding "1 2" \
    "Request Summary" \
    "$(jq -r '
      [
        "Name: " + (.name // ""),
        "Method: " + (.method // "GET"),
        "URL: " + (.url // ""),
        "Body Type: " + (.body_type // "none"),
        "Headers: " + ((.headers // {}) | length | tostring),
        "Query Params: " + ((.query // {}) | length | tostring),
        "Auth: " + (.auth.type // "none")
      ] | join("\n")
    ' <<<"$resolved_json")"
}
