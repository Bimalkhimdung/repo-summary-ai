# Repo Summary AI

A GitHub Action that summarizes recent git commits/pushes (across all branches) into an AI-written digest, using any [Ollama](https://ollama.com) model — Gemma, DeepSeek, Llama, Mistral, whatever you've got running. Works with a local Ollama on a self-hosted runner or an external Ollama server reached over HTTPS.

This action only **generates** the digest (subject + body) as outputs — it deliberately doesn't send email/Slack/etc. itself, so you can pair it with whichever notification action you already use. See [examples/](./examples) for full working workflows.

## What it does

1. Runs `git log`/`git rev-list` across all branches for a given time window (default: the last 24 hours).
2. If there's no activity, outputs a short "no activity" subject/body and stops — no model call made.
3. Otherwise, sends the raw commit log to your Ollama model with a prompt asking for a structured digest: overview paragraph, commits grouped by area/author, callouts for anything that looks like a bug fix or breaking change, and a contributor tally.
4. Strips `<think>...</think>` reasoning leakage some models (e.g. DeepSeek-R1) include in their output.
5. Falls back to a deterministic subject + the raw commit log as the body if Ollama is unreachable, times out, or returns something unparseable — so a flaky model never means a broken workflow, just a plainer digest.

## Usage

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # required — the action needs full history to look back

- name: Generate commit digest
  id: digest
  uses: Bimalkhimdung/repo-summary-ai@v1
  with:
    ollama-url: ${{ secrets.OLLAMA_URL }}
    ollama-model: 'deepseek-r1:14b'   # optional, this is the default

- name: Use the digest however you like
  if: steps.digest.outputs.has-commits == 'true'
  run: |
    echo "Subject: ${{ steps.digest.outputs.subject }}"
    echo "Body:"
    cat "${{ steps.digest.outputs.body-file }}"
```

Full working examples:
- [`examples/commit-digest-email.yml`](./examples/commit-digest-email.yml) — paired with [dawidd6/action-send-mail](https://github.com/dawidd6/action-send-mail)
- [`examples/commit-digest-slack.yml`](./examples/commit-digest-slack.yml) — posted to a Slack webhook

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `ollama-url` | yes | — | Base URL of the Ollama server, e.g. `https://ollama.example.com` or `http://localhost:11434`. No trailing slash. |
| `ollama-model` | no | `gemma2:9b` | Ollama model tag to use. Must already be reachable/pullable on that server. |
| `since` | no | `24 hours ago` | Time window, in `git --since` syntax (e.g. `7 days ago`). |
| `pull-model` | no | `true` | If `true`, asks the server to pull the model when it's not already present. Set `false` if your server has no internet access and you manage models manually. |
| `fetch-timeout` | no | `180` | Timeout (seconds) for the Ollama generate request. Increase for larger/slower models. |

## Outputs

| Output | Description |
|---|---|
| `subject` | AI-generated one-line subject. Falls back to a deterministic `Commit digest for {repo} ({N} commits)` string if the model output couldn't be parsed. |
| `body` | Full digest text, as a string (useful for Slack/Discord/etc. that take text directly). |
| `body-file` | Path to a file containing the same body text (useful for actions that want `body: file://path`, like `dawidd6/action-send-mail`). |
| `commit-count` | Number of commits found in the window. |
| `has-commits` | `"true"`/`"false"` — check this before sending a notification so you don't get spammed on quiet days. |

## Requirements

- Your Ollama server must be reachable from wherever the workflow runs (public HTTPS if using GitHub-hosted runners; `localhost` works fine on a self-hosted runner with Ollama installed on the same box).
- The consuming workflow must check out the repo with `fetch-depth: 0` **before** calling this action — full history is needed to look back over the time window. This action does not run checkout for you (composability again — you might already have checkout configured with options this action shouldn't assume).
- `curl`, `jq`, and `python3` on the runner. All three are preinstalled on GitHub-hosted `ubuntu-latest`/`ubuntu-24.04` runners.

## Security note

If your Ollama endpoint has no authentication in front of it, treat its URL as sensitive — store it in a repo secret (`secrets.OLLAMA_URL`), not a plain variable, and don't post it publicly. Anyone with the URL can query your model and consume your server's compute.

## License

MIT — see [LICENSE](./LICENSE).
