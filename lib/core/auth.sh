#!/usr/bin/env bash

lapits_apply_auth() {
  local request_json="${1:?request json required}"

  jq -c '
    . as $req
    | ($req.auth // {"type":"none"}) as $auth
    | if ($auth.type // "none") == "none" then
        $req
      elif $auth.type == "bearer" then
        .headers = ((.headers // {}) + {"Authorization": ("Bearer " + ($auth.token // ""))})
      elif $auth.type == "basic" then
        .headers = ((.headers // {}) + {"Authorization": ("Basic " + ((($auth.username // "") + ":" + ($auth.password // "")) | @base64))})
      elif $auth.type == "api_key" then
        if (($auth.in // "header") == "query") then
          .query = ((.query // {}) + {($auth.key // "api_key"): ($auth.value // "")})
        else
          .headers = ((.headers // {}) + {($auth.key // "X-API-Key"): ($auth.value // "")})
        end
      elif $auth.type == "oauth2" then
        .headers = ((.headers // {}) + {"Authorization": ("Bearer " + ($auth.access_token // ""))})
      else
        $req
      end
  ' <<<"$request_json"
}
