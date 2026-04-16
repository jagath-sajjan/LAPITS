#!/usr/bin/env bash

lapits_vars_dir() {
  local root_dir
  root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  echo "$root_dir/data/environments"
}

lapits_default_global_vars() {
  cat <<'JSON'
{}
JSON
}

lapits_default_current_env() {
  cat <<'JSON'
{
  "name": "default"
  "variables: {}"
}
JSON
}

lapits_ensure_env_files() {
  local vars_dir global_file current_file
  vars_dir="$(lapits_vars_dir)"
  global_file="$vars_dir/global.json"
  current_file="$vars_dir/current.json"

  mkdir -p "$vars_dir"

  if [ ! -f "$global_file" ]; then
    lapits_default_global_vars > "$global_file"
  fi

  if [ ! -f "$current_file" ]; then
    lapits_default_global_vars > "$current_file"
  fi
}

lapits_load_global_vars() {
  lapits_ensure_env_files 
  cat "$(lapits_vars_dir)/global.json"
}

lapits_load_current_env() {
  lapits_ensure_env_files
  cat "$(lapits_vars_dir)/current.json"
}

lapits_load_current_vars() {
  lapits_load_current_env | jq -c '.variables // {}'
}

lapits_get_merged_vars() {
  local global_json env_json
  global_json="$(lapits_load_global_vars)"
  env_json="$(lapits_load_current_vars)"

  jq -cn \
    --argjson global "$global_json" \
    --argjson env "$env_json" \
    '$global + $env'
}

lapits_interpolate_json() {
  local input_json="${1:?input json required}"
  local vars_json
  vars_json="$(lapits_get_merged_vars)"

  jq -c \
    --argjson vars "$vars_json" '
      def interp($vars):
        walk(
          if type == "string" then
            reduce ($vars | to_entries[]) as $item
              (.;
               gsub("\\{\\{" + ($item.key) + "\\}\\}"; ($item.value|tostring)))
          else
            .
          end
        );
      interp($vars)
    ' <<<"$input_json"
}

lapits_set_current_env_name() {
  local env_name="${1:?env name required}"
  local vars_dir current_file env_file
  vars_dir="$(lapits_vars_dir)"
  current_file="$vars_dir/current.json"
  env_files="$vars_dir/${env_name}.json"

  if [ ! -f "$env_file" ]; then
    echo "Environment not found: $env_name" >&2
    return 1
  fi

  cp "$env_file" "$current_file"
}

lapits_save_env() {
  local env_name="${1:?env name required}"
  local variables_json="${2:?variables json required}"
  local vars_dir env_file

  vars_dir="$(lapits_vars_dir)"
  env_file="$vars_dir/${env_name}.json"

  jq -n \
    --arg name "$env_name" \
    --argjson variables "$variables_json" \
    '{name: $name, variables: $variables}' > "$env_file"
}

lapits_environment_menu() {
  lapits_ensure_env_files

  local vars_dir current_name choice
  vars_dir="$(lapits_vars_dir)"
  current_name="$(lapits_load_current_env | jq -r '.name // "default"')"

  clear
  gum style --border rounded --padding "1 2" "Environment Manager" "Current: $current_name"

  choice=$(gum choose \
    "Use Existing Environment" \
    "Create / Update Environment" \
    "Edit Global Variables" \
    "Back")

  case "$choice" in
    "Use Existing Environment")
      local env_file selected
      mapfile -t env_file < <(find "$vars_dir" -maxdepth 1 -type f -name '*.json' ! -name 'global.json' ! -name 'current.json' -exec basename {} .json \;)
      if [ ${#env_file[@]} -eq 0 ]; then
        gum style --foreground 214 "No saved environments found."
        gum input --placeholder "Press Enter to continue..." >/dev/null
        return 0
      fi
      selected=$(printf '%s\n' "${env_file[@]}" | gum choose)
      lapits_set_current_env_name "$selected"
      gum style --foreground 42 "Active environment set to: $selected"
      gum input --placeholder "Press Enter to continue..." >/dev/null
      ;;
    "Create / Update Environment")
      local env_name kv_lines vars_json
      env_name="$(gum input --placeholder "Environment name (e.g. dev, prod)")"
      if [ -z "$env_name" ]; then
        return 0
      fi
      kv_lines="$(gum write --placeholder $'One variable per line\nExample:\nbaseUrl=https://jsonplaceholder.typicode.com\ntoken=abc123')"
      vars_json="$(lapits_kv_text_to_json "$kv_lines")"
      lapits_save_env "$env_name" "$vars_json"
      gum style --foreground 42 "Saved environment: $env_name"
      gum input --placeholder "Press Enter to continue..." >/dev/null
      ;;
    "Edit Global Variables")
      local existing raw updated
      existing="$(lapits_load_global_vars | jq -r 'to_entries[]? | "\(.key)=\(.value)"')"
      raw="$(printf '%s\n' "$existing" | gum write --placeholder $'One variable per line\nExample:\napiVersion=v1\nteam=lapits')"
      updated="$(lapits_kv_text_to_json "$raw")"
      printf '%s\n' "$updated" > "$(lapits_vars_dir)/global.json"
      gum style --foreground 42 "Global variables updated."
      gum input --placeholder "Press Enter to continue..." >/dev/null
      ;;
    "Back")
      return 0
      ;;
  esac
}

lapits_kv_text_to_json() {
  local input="${1:-}"

  if [ -z "$input" ]; then
    echo "{}"
    return 0
  fi

  awk -F= '
    BEGIN { print "{"; first=1 }
    /^[[:space:]]*$/ { next }
    {
      key=$1
      sub(/^[[:space:]]+/, "", key)
      sub(/[[:space:]]+$/, "", key)

      val=substr($0, index($0,$2))
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
  ' <<<"$input" | jq -c .
}
