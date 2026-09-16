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

IBM's inference API carries the same messages inside a request of its own.

| field | what it is |
| --- | --- |
| `endpoint` | your region's site, with no path: `https://<region>.ml.cloud.ibm.com` |
| `apiKey` | your IBM Cloud API key, which viva exchanges for an access token |
| `projectId` | the project that pays for the call, or `spaceId` for a deployment space |
| `models` | the model ids your project can run, since viva ships no list for watsonx |

viva addresses `/ml/v1/text/chat` on the site, and `/ml/v1/text/chat_stream` to
stream. It mints another access token when the one it holds expires. IBM
refuses a request that names neither a project nor a space, and
`WATSONX_PROJECT_ID` or `WATSONX_SPACE_ID` says one from the environment.

## Checking it

```bash
viva config                  # the settings, and which file set each
viva do --model watsonx/ibm/granite-3-2b-instruct "say hello"
```
