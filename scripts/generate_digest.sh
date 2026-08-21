#!/usr/bin/env bash
#
# Core logic for the "Ollama Commit Digest" action. Collects commits made
# across all branches in the given time window, asks an Ollama model to
# write a subject + body digest, and exposes them as step outputs:
#   subject, body, body-file, commit-count, has-commits
#
# Assumes the CALLER has already checked out the target repo with
# `fetch-depth: 0` before running this action, since this script operates
# on whatever git repo is in the current working directory.
#
# Falls back to a deterministic subject + a raw-log body if Ollama is
# unreachable or returns an empty/unparseable response, so consumers
# always get *something* usable rather than a failed step.

set -euo pipefail

SINCE="${SINCE:-24 hours ago}"
MODEL="${OLLAMA_MODEL:-gemma2:9b}"
OLLAMA_URL="${OLLAMA_URL:?OLLAMA_URL is required}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-180}"
REPO_NAME="${GITHUB_REPOSITORY:-$(basename "$(pwd)")}"

WORKDIR=$(mktemp -d)
SUBJECT_FILE="${WORKDIR}/subject.txt"
BODY_FILE="${WORKDIR}/body.txt"

emit_output() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
  fi
}

emit_multiline_output() {
  # Safe form for values that may contain quotes, %, newlines, etc.
  local key="$1"
  local file="$2"
  local marker="GHA_EOF_$$_${key}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "${key}<<${marker}"
      cat "${file}"
      echo "${marker}"
    } >> "${GITHUB_OUTPUT}"
  fi
}

finish() {
  emit_output "body-file" "${BODY_FILE}"
  emit_multiline_output "subject" "${SUBJECT_FILE}"
  emit_multiline_output "body" "${BODY_FILE}"
}

git fetch --all --prune --quiet || true

LOG=$(git log --all --no-merges --since="${SINCE}" \
  --date=format:'%Y-%m-%d %H:%M' \
  --pretty=format:'---%nCommit: %h%nAuthor: %an%nDate: %ad%nRefs: %D%nMessage: %s%n%b' || true)

if [ -z "$(echo "${LOG}" | tr -d '[:space:]')" ]; then
  echo "No commits or pushes were made to ${REPO_NAME} in the window: ${SINCE}." > "${BODY_FILE}"
  echo "No commit activity in ${REPO_NAME}" > "${SUBJECT_FILE}"
  emit_output "commit-count" "0"
  emit_output "has-commits" "false"
  finish
  echo "No commits found for window: ${SINCE}"
  exit 0
fi

COMMIT_COUNT=$(git rev-list --all --no-merges --since="${SINCE}" --count)
AUTHORS=$(git log --all --no-merges --since="${SINCE}" --pretty=format:'%an' | sort -u | paste -sd, -)

PROMPT_FILE="${WORKDIR}/prompt.txt"
cat > "${PROMPT_FILE}" <<EOF
You are a helpful engineering assistant. You will summarize git activity for
the repository "${REPO_NAME}" over the window "${SINCE}" as a digest. Only
state facts grounded in the commit data below — do not invent details that
aren't present in it.

Respond in EXACTLY this format, with nothing before or after it:

SUBJECT: <one short line, under 100 characters, summarizing the activity — no surrounding quotes>
===BODY===
<the full digest body, plain text only, no markdown symbols like # or **, structured as:
1. A short paragraph giving the high-level picture of what changed and why it likely matters.
2. A bulleted list (use "-" for bullets) grouping related commits by feature/area, mentioning the author for each.
3. A separate short section calling out anything that looks like a bug fix, breaking change, revert, or something that should get extra review.
4. A closing line stating the total commit count (${COMMIT_COUNT}) and the contributors (${AUTHORS}).>

Raw git log (author / date / branch refs / commit message) for the window:
${LOG}
EOF

PROMPT_TEXT=$(cat "${PROMPT_FILE}")

REQUEST_JSON=$(jq -n --arg model "${MODEL}" --arg prompt "${PROMPT_TEXT}" \
  '{model: $model, prompt: $prompt, stream: false}')

set +e
RESPONSE=$(curl -s -m "${FETCH_TIMEOUT}" -X POST "${OLLAMA_URL}/api/generate" \
  -H 'Content-Type: application/json' \
  -d "${REQUEST_JSON}")
CURL_EXIT=$?
set -e

AI_TEXT=""
if [ "${CURL_EXIT}" -eq 0 ] && [ -n "${RESPONSE}" ]; then
  AI_TEXT=$(echo "${RESPONSE}" | jq -r '.response // empty' 2>/dev/null || true)
fi

if [ -z "${AI_TEXT}" ]; then
  echo "Ollama summarization failed or returned an empty response; falling back to the raw log." >&2
  {
    echo "AI summarization was unavailable, so here is the raw activity for ${REPO_NAME} (window: ${SINCE}):"
    echo ""
    echo "${LOG}"
    echo ""
    echo "Total commits: ${COMMIT_COUNT}"
    echo "Contributors: ${AUTHORS}"
  } > "${BODY_FILE}"
  echo "Commit digest for ${REPO_NAME} (AI unavailable, ${COMMIT_COUNT} commits)" > "${SUBJECT_FILE}"
else
  # Strip any <think>...</think> reasoning-model leakage (e.g. deepseek-r1
  # style models emit this even with stream:false), then split the
  # SUBJECT/===BODY=== markers out. Falls back to a deterministic subject
  # if the model didn't follow the requested format.
  REPO_NAME="${REPO_NAME}" COMMIT_COUNT="${COMMIT_COUNT}" \
  SUBJECT_FILE="${SUBJECT_FILE}" BODY_FILE="${BODY_FILE}" \
  python3 - "${AI_TEXT}" <<'PYEOF'
import os
import re
import sys

text = sys.argv[1]
text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL).strip()

subject = ""
body = text

m = re.search(r'^SUBJECT:\s*(.+)$', text, flags=re.MULTILINE)
if m:
    subject = m.group(1).strip().strip('"')
    marker_idx = text.find('===BODY===')
    if marker_idx != -1:
        body = text[marker_idx + len('===BODY==='):].strip()
    else:
        body = text[m.end():].strip()

if not subject:
    repo = os.environ.get('REPO_NAME', 'repository')
    count = os.environ.get('COMMIT_COUNT', '0')
    plural = '' if count == '1' else 's'
    subject = f"Commit digest for {repo} ({count} commit{plural})"

subject = subject.replace('\n', ' ').strip()
if len(subject) > 150:
    subject = subject[:147] + "..."

with open(os.environ['SUBJECT_FILE'], 'w') as f:
    f.write(subject + "\n")

with open(os.environ['BODY_FILE'], 'w') as f:
    f.write((body if body else text) + "\n")
PYEOF
fi

emit_output "commit-count" "${COMMIT_COUNT}"
emit_output "has-commits" "true"
finish

