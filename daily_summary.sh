#!/usr/bin/env bash
#
# Collects commits made across all branches in the given time window, asks
# an Ollama model to write a human-readable digest (subject line included),
# and writes:
#   - summary_subject.txt  -> the email subject
#   - summary_body.txt     -> the email body
# Both are also exposed as step outputs (subject / body_file) so the
# workflow can reference them directly.
#
# Falls back to a plain (non-AI) digest of the raw git log if Ollama is
# unreachable or returns an empty response, so the daily email still goes
# out even when the model call fails. A deterministic subject line is
# always produced, even on fallback paths.

set -euo pipefail

SINCE="${SINCE:-24 hours ago}"
MODEL="${OLLAMA_MODEL:-deepseek-r1:latest}"
# Fallback only — the workflow always passes OLLAMA_URL in from the
# OLLAMA_URL repo secret, so this default is only hit if you run this
# script by hand without setting that env var.
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
REPO_NAME="${GITHUB_REPOSITORY:-$(basename "$(pwd)")}"
TODAY="${TODAY:-$(date +'%Y-%m-%d')}"

emit_subject_output() {
  # Writes the current summary_subject.txt content to the `subject` step
  # output, using the safe multiline heredoc form so special characters
  # (quotes, %, etc.) in an AI-written subject can't break the workflow.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "subject<<SUBJECT_EOF_MARKER"
      cat summary_subject.txt
      echo "SUBJECT_EOF_MARKER"
    } >> "${GITHUB_OUTPUT}"
  fi
}

git fetch --all --prune --quiet || true

LOG=$(git log --all --no-merges --since="${SINCE}" \
  --date=format:'%Y-%m-%d %H:%M' \
  --pretty=format:'---%nCommit: %h%nAuthor: %an%nDate: %ad%nRefs: %D%nMessage: %s%n%b' || true)

if [ -z "$(echo "${LOG}" | tr -d '[:space:]')" ]; then
  echo "No commits or pushes were made to ${REPO_NAME} in the last window (${SINCE})." > summary_body.txt
  echo "Daily commit summary for ${REPO_NAME} — ${TODAY}: no activity" > summary_subject.txt
  emit_subject_output
  echo "No commits found for window: ${SINCE}"
  exit 0
fi

COMMIT_COUNT=$(git rev-list --all --no-merges --since="${SINCE}" --count)
AUTHORS=$(git log --all --no-merges --since="${SINCE}" --pretty=format:'%an' | sort -u | paste -sd, -)

PROMPT_FILE=$(mktemp)
cat > "${PROMPT_FILE}" <<EOF
You are a helpful engineering assistant. You will summarize git activity for
the repository "${REPO_NAME}" over the window "${SINCE}" as a daily digest
email. Only state facts grounded in the commit data below — do not invent
details that aren't present in it.

Respond in EXACTLY this format, with nothing before or after it:

SUBJECT: <one short line, under 100 characters, summarizing today's activity — no quotes around it>
===BODY===
<the full email body, plain text only, no markdown symbols like # or **, structured as:
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
RESPONSE=$(curl -s -m 180 -X POST "${OLLAMA_URL}/api/generate" \
  -H 'Content-Type: application/json' \
  -d "${REQUEST_JSON}")
CURL_EXIT=$?
set -e

AI_TEXT=""
if [ "${CURL_EXIT}" -eq 0 ] && [ -n "${RESPONSE}" ]; then
  AI_TEXT=$(echo "${RESPONSE}" | jq -r '.response // empty' 2>/dev/null || true)
fi

if [ -z "${AI_TEXT}" ]; then
  echo "Ollama summarization failed or returned an empty response; sending raw log instead." >&2
  {
    echo "AI summarization was unavailable, so here is the raw activity for ${REPO_NAME} (window: ${SINCE}):"
    echo ""
    echo "${LOG}"
    echo ""
    echo "Total commits: ${COMMIT_COUNT}"
    echo "Contributors: ${AUTHORS}"
  } > summary_body.txt
  echo "Daily commit summary for ${REPO_NAME} — ${TODAY} (AI summary unavailable, ${COMMIT_COUNT} commits)" > summary_subject.txt
else
  # Post-process with python3: strip any <think>...</think> reasoning-model
  # leakage (e.g. deepseek-r1 style models emit this in .response), then
  # split the SUBJECT/===BODY=== markers out. Falls back to a deterministic
  # subject if the model didn't follow the requested format.
  REPO_NAME="${REPO_NAME}" COMMIT_COUNT="${COMMIT_COUNT}" TODAY="${TODAY}" \
  python3 - "${AI_TEXT}" <<'PYEOF'
import os
import re
import sys

text = sys.argv[1]

# Strip <think>...</think> blocks that reasoning models (e.g. deepseek-r1)
# sometimes include in their response even with stream:false.
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
    today = os.environ.get('TODAY', '')
    plural = '' if count == '1' else 's'
    subject = f"Daily commit summary for {repo} — {today} ({count} commit{plural})"

subject = subject.replace('\n', ' ').strip()
if len(subject) > 150:
    subject = subject[:147] + "..."

with open('summary_subject.txt', 'w') as f:
    f.write(subject + "\n")

with open('summary_body.txt', 'w') as f:
    f.write((body if body else text) + "\n")
PYEOF
fi

emit_subject_output
rm -f "${PROMPT_FILE}"
