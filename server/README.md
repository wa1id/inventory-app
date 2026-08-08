# Recognition service

Turns one item photo into an editable suggestion for the Inventory app
(issue #7). Deployed on Vercel.

The provider credential lives here and never ships in the mobile bundle — that
is the whole reason this service exists rather than the app calling a model
directly.

## Architecture

Three named patterns, doing one job: make the vision model a swappable part.

```
api/recognize.ts        HTTP + wire contract v1   ─┐
src/port.ts             VisionAdapter interface    │  depends only on the port
src/prompt.ts           shared prompt + schema     │
src/registry.ts         id → adapter               │
src/adapters/
  gatewayVision.ts      one adapter, many models  ─┐  depends on a vendor SDK
  mimoVision.ts         Xiaomi MiMo, direct API   ─┘
  index.ts              registrations
```

- **Adapter** — each provider module translates a vendor SDK into `VisionAdapter`.
- **Strategy** — adapters are interchangeable at runtime; callers hold the
  interface, never a concrete provider.
- **Registry** — `id → factory`, so selecting a model is a string, not a branch.

Architecturally this is **Ports and Adapters**: `src/port.ts` is the port,
everything under `src/adapters/` is an adapter. The rule that keeps it honest:
**nothing outside `src/adapters/` may import a provider SDK.**

The prompt and the output schema live in `src/prompt.ts`, deliberately _outside_
the adapters. Two models pointed at the same photo must answer the same
question, or comparing them measures prompt differences rather than model
quality. An adapter's only jobs are transport and error classification.

## Adding a model

One line in `src/adapters/index.ts`:

```ts
registerAdapter('gpt-mini', () =>
  createGatewayVisionAdapter({
    id: 'gpt-mini',
    label: 'GPT-4.1 mini',
    model: 'openai/gpt-4.1-mini',
  }),
);
```

The AI Gateway fronts every major provider, so a different model is a different
string. Verify ids against the live list — ids recalled from memory are
routinely stale:

```bash
curl -s https://ai-gateway.vercel.sh/v1/models | jq -r '.data[].id'
```

## Adding a provider the gateway does not front

Self-hosted model, a vendor with no gateway support, or one whose SDK you need
directly:

1. Write `src/adapters/<name>.ts` exporting something that satisfies
   `VisionAdapter` — use `gatewayVision.ts` as the shape.
2. Classify that provider's failures into `timeout` / `rate_limited` /
   `upstream`.
3. Add one `registerAdapter` line.

Nothing else changes: not the HTTP layer, not the contract, not the client.

`mimoVision.ts` is the worked example. Xiaomi MiMo is not on the gateway, and
although its API is OpenAI-shaped, only the _transport_ is:

- **Tool calls are unusable.** The model writes `<tool_call>…</tool_call>` into
  the message content and returns `tool_calls: null`. Structured output has to
  go through JSON mode.
- **`strict: true` on the JSON schema is accepted and ignored.** A photo it
  cannot name comes back as `{"identified": false}` with every other field
  missing, HTTP 200. Validating that against the shared schema throws, which
  would have reported an honest "could not tell" as a provider failure — the
  user would read "suggestions are unavailable" instead of being sent to manual
  entry. The adapter parses loosely and fills the gaps itself.

That is the pattern to copy: absorb a provider's quirks inside its adapter, and
hand the rest of the service the same shape every other provider hands it.

## Choosing which model answers

| Where          | How                                                   |
| -------------- | ----------------------------------------------------- |
| Per deployment | `RECOGNITION_ADAPTER` env var (default `mimo`)        |
| Per request    | `"adapter": "<id>"` in the request body, for A/B runs |

The gateway adapters authenticate via Vercel OIDC and need no key. `mimo` is
called directly, so **any deployment serving it needs `MIMO_API_KEY` set** —
without it every request answers 502 (immediately, without spending a call).
`GET /api/adapters` keeps working either way, so it stays usable for diagnosis.

Unknown ids are rejected rather than silently falling back — quietly serving a
different model than requested makes A/B results meaningless and cost
surprises invisible.

## Endpoints

`POST /api/recognize` — contract v1, shared with the client's
`src/services/ai/contract.ts`. Treat the two files as one unit.

```jsonc
// request
{ "contractVersion": 1,
  "image": { "data": "<base64>", "encoding": "base64", "mediaType": "image/jpeg" },
  "adapter": "claude-haiku",         // optional
  "nameHint": "Angle grinder" }      // optional

// 200 — a suggestion
{ "contractVersion": 1, "suggestion": { "name": "Cordless Drill", "category": "Power Tools",
  "tags": ["dewalt","18v"], "confidence": 0.92 } }

// 200 — looked, could not tell
{ "contractVersion": 1, "status": "unrecognized" }

// 429 rate limited · 504 timeout · 502 upstream
```

Every failure is one the client already downgrades to manual entry.

The suggestion carried `estimatedValue` and `currency` until the app dropped
value estimates entirely. Both are gone from the schema, the prompt, and the
response — still additive-compatible in both directions, since an older client
reads the missing fields as absent and an older service's extra ones are
ignored.

### `nameHint` — answering again after the user corrects us

A wrong name is not a wrong name in isolation: category, tags, and value were
all derived from it, so correcting the title alone leaves an item filed under
the previous guess. When the user does that and asks for the rest to be
updated, the app sends their title as `nameHint`. The model is then told the
name is authoritative and asked to derive the supporting fields for _that_
item, using the photo as evidence about condition, size, and brand. The hint
overrides whatever `name` the model echoes back, so its wording cannot undo the
user's correction.

Additive within v1, in both directions: a client that never sends it is
byte-identical to before, and a deployment predating it ignores the field and
answers from the photo alone — a worse answer, never a broken one. The hint is
user-authored text that ends up in a prompt, so `parseRequest` collapses it to
one line and clamps it to 80 characters; every field of the answer is still
schema-checked and normalized as usual.

`GET /api/adapters` — ids, labels, and which is default. Useful for confirming
a redeploy actually changed the model. Exposes no secrets.

## Local development

```bash
npm install
npx vercel env pull .env.local   # writes VERCEL_OIDC_TOKEN for gateway auth
echo "MIMO_API_KEY=sk-..." >> .env.local   # only for the mimo adapter
npm run typecheck
npm test                         # contract, registry, and normalization
```

`npm test` covers everything except the provider call itself; hitting a real
model needs gateway credit or a MiMo key.

## Privacy

Logs carry timings, outcome class, image byte count, and confidence — never the
image, the suggestion text, or anything the user typed. This mirrors the
allowlist the mobile client enforces on its own telemetry.
