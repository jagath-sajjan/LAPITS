#!/usr/bin/env bash

lapits_curl_import_to_request() {
  local curl_cmd="${1:?curl command required}"

  CURL_INPUT="$curl_cmd" python3 - <<'PY'
import os, shlex, json

cmd = os.environ["CURL_INPUT"].strip()
parts = shlex.split(cmd)

if not parts:
    raise SystemExit("Empty curl command")

if parts[0] != "curl":
    raise SystemExit("Command must start with curl")

method = "GET"
url = ""
headers = {}
query = {}
body_type = "none"
body = ""
auth = {"type": "none"}

i = 1
while i < len(parts):
    token = parts[i]

    if token in ("-X", "--request") and i + 1 < len(parts):
        method = parts[i + 1].upper()
        i += 2
        continue

    if token in ("-H", "--header") and i + 1 < len(parts):
        raw = parts[i + 1]
        if ":" in raw:
            k, v = raw.split(":", 1)
            headers[k.strip()] = v.strip()
        i += 2
        continue

    if token in ("-d", "--data", "--data-raw", "--data-binary", "--data-urlencode") and i + 1 < len(parts):
        data_val = parts[i + 1]
        body = data_val
        ct = headers.get("Content-Type", "").lower()

        if token == "--data-binary":
            body_type = "binary"
        elif "application/json" in ct:
            body_type = "json"
        elif "application/x-www-form-urlencoded" in ct or token == "--data-urlencode":
            body_type = "x-www-form-urlencoded"
        else:
            body_type = "raw"

        if method == "GET":
            method = "POST"

        i += 2
        continue

    if token in ("-F", "--form") and i + 1 < len(parts):
        field = parts[i + 1]
        body_type = "form-data"
        if body:
            body += "\n" + field
        else:
            body = field
        if method == "GET":
            method = "POST"
        i += 2
        continue

    if token in ("-u", "--user") and i + 1 < len(parts):
        userpass = parts[i + 1]
        if ":" in userpass:
            username, password = userpass.split(":", 1)
        else:
            username, password = userpass, ""
        auth = {
            "type": "basic",
            "username": username,
            "password": password
        }
        i += 2
        continue

    if token.startswith("http://") or token.startswith("https://"):
        url = token
        i += 1
        continue

    i += 1

if not url:
    raise SystemExit("No URL found in curl command")

result = {
    "name": "Imported cURL Request",
    "method": method,
    "url": url,
    "headers": headers,
    "query": query,
    "body_type": body_type,
    "body": body,
    "auth": auth
}

print(json.dumps(result))
PY
}

lapits_request_to_curl() {
  local request_json="${1:?request json required}"

  jq -r '
    def headers_to_args:
      (.headers // {})
      | to_entries
      | map("-H " + ((.key + ": " + .value) | @sh))
      | join(" ");

    def query_to_url($url):
      if ((.query // {}) | length) == 0 then
        $url
      else
        $url + "?" + (
          (.query // {})
          | to_entries
          | map((.key|@uri) + "=" + (.value|tostring|@uri))
          | join("&")
        )
      end;

    . as $r
    | "curl -X " + ($r.method // "GET")
      + " "
      + (headers_to_args)
      + (if ((.body_type // "none") == "json") then
           " --data " + ((.body // "") | @sh)
         elif ((.body_type // "none") == "raw") then
           " --data-raw " + ((.body // "") | @sh)
         elif ((.body_type // "none") == "x-www-form-urlencoded") then
           " --data " + ((.body // "") | @sh)
         elif ((.body_type // "none") == "binary") then
           " --data-binary " + ((.body // "") | @sh)
         elif ((.body_type // "none") == "form-data") then
           (
             (.body // "")
             | split("\n")
             | map(select(length > 0))
             | map(" -F " + (@sh))
             | join("")
           )
         else
           ""
         end)
      + " "
      + ((query_to_url(.url // "")) | @sh)
  ' <<<"$request_json"
}
