# ai: local LLMs

The `ai` stack runs Open WebUI, a ChatGPT-style web interface, in front of Ollama running natively on the Mac.

| Component | Runs as | Local port | Tailnet URL |
|---|---|---|---|
| Open WebUI | container `chi-open-webui` | 3080 | `https://<TS_FQDN>:8003` |
| Ollama | Homebrew login service | 11434 (127.0.0.1) | not published |

Ollama runs on the host because containers on macOS cannot use the Metal GPU
([Architecture](../architecture.md#why-some-things-are-native)). Open WebUI reaches it at
`http://host.docker.internal:11434`.

## Enable

1. Add `ai` to `CHI_STACKS` in `.env`.
2. Install Ollama and start the stack:

   ```bash
   chi bootstrap ollama      # brew install ollama + brew services start ollama
   chi up ai
   chi serve
   ```

`chi up ai` runs `stacks/ai/pre-up.sh`, which warns if Ollama is not responding. Open WebUI still starts, but
has no models until Ollama is up.

## Configure

Pull a model sized for your memory (browse <https://ollama.com/library>):

```bash
ollama pull <model>
ollama list
ollama ps          # loaded models and whether they run 100% on the GPU
```

Open `https://<TS_FQDN>:8003`. The first account you create becomes the admin; later sign-ups need admin
approval.

### Memory planning

Unified memory is shared by the CPU, the GPU (models) and the container VM. A rough budget:

| Mac memory | Suggested stacks | Model size |
|---|---|---|
| 16 GB | `core`, `automation`, `vault`, `media`; `ai` with small models; avoid `photos` | up to ~8B parameters (Q4, ~5 GB) |
| 24 GB | all stacks | 8B-14B |
| 32 GB | all stacks with headroom | ~14B-32B |
| 64 GB+ | all stacks | 32B-70B (70B Q4 is ~40 GB) |

Rule of thumb: a model uses its file size plus 2-4 GB. By default macOS lets the GPU use roughly two thirds to
three quarters of unified memory.

### Using models from other services

- n8n: in the Ollama node, set the base URL to `http://host.docker.internal:11434`.
- Open WebUI's knowledge base gives you local retrieval over your own documents.

## Operate

```bash
chi ps ai
chi logs ai
brew services restart ollama
chi update          # upgrades Ollama (and restarts it) and the Open WebUI image
```

## Troubleshoot

| Symptom | Check |
|---|---|
| Open WebUI shows no models | `curl http://127.0.0.1:11434/api/version`; `brew services start ollama`; `ollama list`. |
| Generation is slow | `ollama ps`: if the model is not 100% GPU, it is too large for your memory. Use a smaller one. |
| Ollama not running after reboot | It is a login service: check auto-login (`chi doctor`). |
| Colima: Open WebUI cannot reach Ollama | Containers may not reach the host's `127.0.0.1`. Make Ollama listen on all interfaces (`launchctl setenv OLLAMA_HOST 0.0.0.0`, restart the service) and keep the firewall on. OrbStack does not need this. |

## Security notes

Ollama has no authentication. Keep it on `127.0.0.1` and never publish port 11434 on the tailnet or LAN; use
Open WebUI for remote access.
