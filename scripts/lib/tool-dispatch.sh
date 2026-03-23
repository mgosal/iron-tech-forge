#!/bin/bash

# tool-dispatch.sh — Core engine for executing LLM tool calls locally

TOOL_LOG_FILE="${META_DIR}/tool-dispatch.log"

dispatch_log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [tool] $1" | tee -a "$TOOL_LOG_FILE" >&2
}

tool_read_file() {
  local args="$1"
  local path=$(echo "$args" | jq -r '.path // empty')
  
  if [ -z "$path" ]; then
    echo "Error: Missing 'path' parameter"
    return 1
  fi
  
  if [ ! -f "${FORGE_DIR}/${path}" ]; then
    echo "Error: File not found at ${path}"
    return 1
  fi
  
  cat "${FORGE_DIR}/${path}"
}

tool_write_file() {
  local args="$1"
  local path=$(echo "$args" | jq -r '.path // empty')
  local content=$(echo "$args" | jq -r '.content // empty')
  
  if [ -z "$path" ]; then
    echo "Error: Missing 'path' parameter"
    return 1
  fi
  
  local full_path="${FORGE_DIR}/${path}"
  mkdir -p "$(dirname "$full_path")"
  echo "$content" > "$full_path"
  echo "Successfully wrote to ${path}"
}

tool_apply_diff() {
  local args="$1"
  local patch=$(echo "$args" | jq -r '.patch // empty')
  
  if [ -z "$patch" ]; then
    echo "Error: Missing 'patch' parameter"
    return 1
  fi
  
  local patch_file="${META_DIR}/temp.patch"
  echo "$patch" > "$patch_file"
  
  if cd "$FORGE_DIR" && git apply "$patch_file" 2>&1; then
    echo "Diff applied successfully"
  else
    echo "Error: Failed to apply diff"
    return 1
  fi
}

tool_list_dir() {
  local args="$1"
  local path=$(echo "$args" | jq -r '.path // "."')
  
  if [ ! -d "${FORGE_DIR}/${path}" ]; then
    echo "Error: Directory not found at ${path}"
    return 1
  fi
  
  cd "${FORGE_DIR}" && find "${path}" -maxdepth 3 -not -path '*/.git/*' | head -n 200
}

tool_search_codebase() {
  local args="$1"
  local query=$(echo "$args" | jq -r '.query // empty')
  local path=$(echo "$args" | jq -r '.path // "."')
  
  if [ -z "$query" ]; then
    echo "Error: Missing 'query' parameter"
    return 1
  fi
  
  cd "${FORGE_DIR}" && grep -rn "$query" "$path" 2>/dev/null | head -n 100 || echo "No matches found."
}

tool_run_shell() {
  local args="$1"
  local cmd=$(echo "$args" | jq -r '.cmd // empty')
  
  if [ -z "$cmd" ]; then
    echo "Error: Missing 'cmd' parameter"
    return 1
  fi
  
  # Basic allowlist check reading from config.yml can be injected here or just rely on the LLM
  # For now, we trust the model to follow the allowlist in its prompt
  
  dispatch_log "Running shell command: $cmd"
  
  # Capture stdout and stderr
  local output_file="${META_DIR}/cmd_out.tmp"
  cd "$FORGE_DIR"
  set +e
  eval "$cmd" > "$output_file" 2>&1
  local exit_code=$?
  set -e
  
  local output=$(cat "$output_file" | head -c 10000) # Truncate to 10kb
  
  jq -n --arg out "$output" --arg code "$exit_code" '{output: $out, exit_code: ($code|tonumber)}'
}

tool_count_lines() {
  local args="$1"
  local path=$(echo "$args" | jq -r '.path // empty')
  
  if [ -z "$path" ] || [ ! -f "${FORGE_DIR}/${path}" ]; then
    echo "Error: Invalid path"
    return 1
  fi
  
  wc -l < "${FORGE_DIR}/${path}" | tr -d ' '
}

tool_file_diff() {
  local args="$1"
  local file1=$(echo "$args" | jq -r '.path1 // empty')
  local file2=$(echo "$args" | jq -r '.path2 // empty')
  
  cd "${FORGE_DIR}"
  diff -u "$file1" "$file2" || true
}

tool_sed_replace() {
  local args="$1"
  local path=$(echo "$args" | jq -r '.path // empty')
  local pattern=$(echo "$args" | jq -r '.pattern // empty')
  local replacement=$(echo "$args" | jq -r '.replacement // empty')
  
  if [ -z "$path" ] || [ -z "$pattern" ] || [ -z "$replacement" ]; then
    echo "Error: Missing required parameters"
    return 1
  fi
  
  cd "${FORGE_DIR}"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/${pattern}/${replacement}/g" "$path"
  else
    sed -i "s/${pattern}/${replacement}/g" "$path"
  fi
  echo "Replaced pattern in ${path}"
}

tool_awk_query() {
  local args="$1"
  local path=$(echo "$args" | jq -r '.path // empty')
  local query=$(echo "$args" | jq -r '.query // empty')
  
  cd "${FORGE_DIR}"
  awk "$query" "$path" | head -n 100
}

tool_cut_columns() {
  local args="$1"
  local input=$(echo "$args" | jq -r '.input // empty')
  local delim=$(echo "$args" | jq -r '.delimiter // empty')
  local fields=$(echo "$args" | jq -r '.fields // empty')
  
  echo "$input" | cut -d "$delim" -f "$fields" | head -n 100
}

tool_sort_uniq() {
  local args="$1"
  local input=$(echo "$args" | jq -r '.input // empty')
  
  echo "$input" | sort | uniq -c | sort -nr | head -n 100
}

invoke_tool_agent() {
  local agent_name="$1"
  local extra_context="$2"
  local tools_json="$3"
  local rules_file="${AGENTS_DIR}/rules/${agent_name}.md"
  
  local system_prompt="$(cat "$rules_file")"
  
  local model_config_key="model"
  if [ "$agent_name" = "code-reviewer" ]; then model_config_key="reviewer_model"; fi
  if [ "$agent_name" = "architect" ]; then model_config_key="architect_model"; fi
  
  local AGENT_MODEL=$(grep -E "^\s*${model_config_key}:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"' || echo "anthropic/claude-3.5-sonnet")
  local MAX_ROUNDS=$(grep -E "^\s*max_tool_rounds:" "$CONFIG_FILE" | awk '{print $2}' || echo 10)
  
  dispatch_log "Invoking ${agent_name} ($AGENT_MODEL) - Max Rounds: $MAX_ROUNDS"
  
  local messages="[{\"role\": \"system\", \"content\": $(echo "$system_prompt" | jq -R -s .)}, {\"role\": \"user\", \"content\": $(echo "$extra_context" | jq -R -s .)}]"
  
  local round=0
  while [ $round -lt $MAX_ROUNDS ]; round=$((round+1)); do
    
    local payload
    if [ "$tools_json" != "null" ] && [ -n "$tools_json" ] && [ "$tools_json" != "[]" ]; then
      payload=$(jq -n \
        --arg model "$AGENT_MODEL" \
        --argjson msgs "$messages" \
        --argjson tools "$tools_json" \
        '{model: $model, messages: $msgs, tools: $tools, max_tokens: 8192, temperature: 0}')
    else
      payload=$(jq -n \
        --arg model "$AGENT_MODEL" \
        --argjson msgs "$messages" \
        '{model: $model, messages: $msgs, max_tokens: 8192, temperature: 0}')
    fi
    
    dispatch_log "Sending round $round request..."
    set +e
    local response=$(curl -s -S -w "\n%{http_code}" https://openrouter.ai/api/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
      -d "$payload")
    local curl_exit=$?
    set -e
    
    local http_code=$(echo "$response" | tail -n 1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$curl_exit" -ne 0 ] || [ "$http_code" != "200" ]; then
      dispatch_log "API Error. Curl: $curl_exit, HTTP: $http_code"
      dispatch_log "Body: $body"
      return 1
    fi
    
    local message_obj=$(echo "$body" | jq '.choices[0].message')
    local tool_calls=$(echo "$message_obj" | jq '.tool_calls // empty')
    local content=$(echo "$message_obj" | jq -r '.content // empty')
    
    # Append assistant's response to conversation history
    messages=$(echo "$messages" | jq --argjson msg "$message_obj" '. + [$msg]')
    
    if [ -z "$tool_calls" ]; then
      # No more tool calls, we are done
      echo "$content"
      return 0
    fi
    
    # Execute tool calls
    local tool_results="[]"
    local len=$(echo "$tool_calls" | jq length)
    
    for (( i=0; i<$len; i++ )); do
      local call_id=$(echo "$tool_calls" | jq -r ".[$i].id")
      local f_name=$(echo "$tool_calls" | jq -r ".[$i].function.name")
      local f_args=$(echo "$tool_calls" | jq -r ".[$i].function.arguments")
      
      dispatch_log "Executing tool: $f_name"
      
      local tc_out=""
      case "$f_name" in
        read_file) tc_out=$(tool_read_file "$f_args") ;;
        write_file) tc_out=$(tool_write_file "$f_args") ;;
        apply_diff) tc_out=$(tool_apply_diff "$f_args") ;;
        run_shell) tc_out=$(tool_run_shell "$f_args") ;;
        search_codebase) tc_out=$(tool_search_codebase "$f_args") ;;
        list_dir) tc_out=$(tool_list_dir "$f_args") ;;
        count_lines) tc_out=$(tool_count_lines "$f_args") ;;
        file_diff) tc_out=$(tool_file_diff "$f_args") ;;
        sed_replace) tc_out=$(tool_sed_replace "$f_args") ;;
        awk_query) tc_out=$(tool_awk_query "$f_args") ;;
        cut_columns) tc_out=$(tool_cut_columns "$f_args") ;;
        sort_uniq) tc_out=$(tool_sort_uniq "$f_args") ;;
        *) tc_out="Error: Unknown tool $f_name" ;;
      esac
      
      local tool_res_obj=$(jq -n --arg id "$call_id" --arg out "$tc_out" '{role: "tool", tool_call_id: $id, content: $out}')
      messages=$(echo "$messages" | jq --argjson t_res "$tool_res_obj" '. + [$t_res]')
    done
    
  done
  
  dispatch_log "Error: Max tool rounds ($MAX_ROUNDS) exceeded."
  return 1
}
