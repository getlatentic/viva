# Example configuration

Two files, and you need neither to start.

| file | goes to | holds |
| --- | --- | --- |
| `config` | `~/.viva/config`, or a project's `.viva/config` | settings, as `key = value` |
| `auth.json` | `~/.viva/auth.json` | one entry per provider, and nothing else |

A project's `config` beats the machine's, the environment beats both, and a
flag beats all three. `viva config` prints every setting with the file that
decided it. Keys stay out of `config`, because a project commits that file.

## Providers

`deepseek`, `openai`, `openrouter` and `bedrock` take an `apiKey`. `local`
(llama.cpp) and `ollama` need none, and an entry as short as `{}` turns one on.
`endpoint` reaches another deployment, and `models` replaces the list a
provider offers.

## watsonx

IBM's gateway speaks the same chat completions as the rest. Three things differ:

- The endpoint carries your region: `https://<region>.ml.cloud.ibm.com/ml/gateway/v1/chat/completions`.
- The key is your IBM Cloud API key. viva exchanges it for an access token and
  mints another when that one expires.
- `models` are the aliases your gateway serves, so viva ships no list for it.
  `viva do --model watsonx/<alias>` then names one.

## Checking it

```bash
viva config                  # the settings, and which file set each
viva do --model watsonx/<alias> "say hello"
```
