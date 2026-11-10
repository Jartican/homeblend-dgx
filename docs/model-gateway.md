# Model gateway design

Exocortex calls capability routes, never concrete model IDs. A route resolves to a profile, and a profile selects a provider plus model.

Examples:

- `interactive-code` can use a small GPU-resident local model.
- `background-vision` can use a slower local model with RAM spill.
- Either route can later point to an OpenAI or Anthropic profile without changing ingestion or agent code.

Provider adapters normalize responses to `{ text, model, usage, providerResponse }`. Keep provider-specific features behind explicit gateway options as they are needed; do not leak provider SDK objects into domain code.

To switch a route, edit `config/models.json`. For production, we can add layered configuration so environment/deployment overrides do not modify the checked-in defaults.

The first supported request shape is deliberately small: `messages`, `temperature`, `maxOutputTokens`, cancellation `signal`, and optional OpenAI-compatible `tools`/`responseFormat`. Streaming, tool-result normalization, retries, fallbacks, budgets, and observability should be added at this boundary.
