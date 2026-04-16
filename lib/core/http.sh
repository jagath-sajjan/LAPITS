#!/usr/bin/env bash

lapits_execute_request() {
  local request_json="${1:?request json required}"
  local resolved_json
  local tmp_dir response_body response_headers response_meta
  local url method body_type body
  local curl_args=()

  resolved_json="$(lapits_interpolate_json "$request_json")"
  resolved_json="$(lapits_apply_auth "$resolved_json")"

  tmp_dir="$(mktemp -d)"
  response_body="$tmp_dir/body.out"
  response_headers="$tmp_dir/headers.out"
  response_meta="$tmp_dir/meta.out"

  method="$(jq -r '.method // "GET"' <<<"$resolved_json")"
  url="$(jq -r '.url // ""' <<<"$resolved_json")"
  body_type="$(jq -r '.body_type // "none"' <<<"$resolved_json")"
  body="$(jq -r '.body // ""' <<<"$resolved_json")"

  if [ -z "$url" ]; then
    echo "URL is required" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  local final_url
  final_url="$(jq -nr \
    --arg url "$url" \
    --argjson query "$(jq -c '.query // {}' <<<"$resolved_json")" '
      if ($query | length) == 0 then
        $url
      else
        $url + "?" + (
          $query
          | to_entries
          | map((.key|@uri) + "=" + (.value|tostring|@uri))
          | join("&")
        )
      end
    ')"

  curl_args+=(-sS -X "$method" "$final_url")
  curl_args+=(-D "$response_headers")
  curl_args+=(-o "$response_body")
  curl_args+=(-w "%{http_code}|%{time_total}|%{size_download}")

  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] && curl_args+=(-H "$key: $value")
  done < <(jq -r '.headers // {} | to_entries[]? | [.key, (.value|tostring)] | @tsv' <<<"$resolved_json")

  case "$body_type" in
    "json")
      curl_args+=(-H "Content-Type: application/json")
      curl_args+=(--data "$body")
      ;;
    "raw")
      curl_args+=(--data-raw "$body")
      ;;
    "x-www-form-urlencoded")
      curl_args+=(-H "Content-Type: application/x-www-form-urlencoded")
      curl_args+=(--data "$body")
      ;;
    "binary")
      curl_args+=(--data-binary "$body")
      ;;
    "form-data")
      while IFS= read -r line; do
        [ -n "$line" ] && curl_args+=(-F "$line")
      done <<<"$body"
      ;;
    "none")
      ;;
    *)
      ;;
  esac

  curl "${curl_args[@]}" > "$response_meta"

  local meta status time_total size_download body_content headers_json
  meta="$(cat "$response_meta")"
  status="${meta%%|*}"
  meta="${meta#*|}"
  time_total="${meta%%|*}"
  size_download="${meta#*|}"
  body_content="$(cat "$response_body")"
  headers_json="$(lapits_headers_file_to_json "$response_headers")"

  jq -n \
    --arg status "$status" \
    --arg time "$time_total" \
    --arg size "$size_download" \
    --arg body "$body_content" \
    --argjson headers "$headers_json" \
    '{
      status: ($status | tonumber),
      time_seconds: ($time | tonumber),
      size_bytes: ($size | tonumber),
      headers: $headers,
      body: $body
    }'

  rm -rf "$tmp_dir"
}

lapits_headers_file_to_json() {
  local headers_file="${1:?headers file required}"

  awk '
    BEGIN { print "{"; first=1 }
    /^[[:space:]]*HTTP\// { next }
    /^[[:space:]]*$/ { next }
    {
      line=$0
      split(line, arr, ":")
      key=arr[1]
      sub(/^[[:space:]]+/, "", key)
      sub(/[[:space:]]+$/, "", key)

      val=substr(line, index(line, ":") + 1)
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)

      gsub(/\\/,"\\\\",key)
      gsub(/"/,"\\\"",key)
      gsub(/\\/,"\\\\",val)
      gsub(/"/,"\\\"",val)

      if (!first) print ","
      printf "\"%s\":\"%s\"", key, val
      first=0
    }
    END { print "\n}" }
  ' "$headers_file" | jq -c .
}

lapits_render_response() {
  local response_json="${1:?response json required}"
  local status time_seconds size_bytes body pretty_body color

  status="$(jq -r '.status' <<<"$response_json")"
  time_seconds="$(jq -r '.time_seconds' <<<"$response_json")"
  size_bytes="$(jq -r '.size_bytes' <<<"$response_json")"
  body="$(jq -r '.body' <<<"$response_json")"

  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    color="42"
  elif [ "$status" -ge 400 ] && [ "$status" -lt 500 ]; then
    color="214"
  elif [ "$status" -ge 500 ]; then
    color="196"
  else
    color="99"
  fi

  clear
  gum style --border rounded --padding "1 2" \
    --foreground "$color" \
    "Status: $status" \
    "Time: ${time_seconds}s" \
    "Size: ${size_bytes} bytes"

  if echo "$body" | jq . >/dev/null 2>&1; then
    pretty_body="$(echo "$body" | jq .)"
  else
    pretty_body="$body"
  fi

  echo
  gum style --bold "Response Body"
  echo "$pretty_body"
  echo

  gum input --placeholder "Press Enter to continue..." >/dev/null
}
