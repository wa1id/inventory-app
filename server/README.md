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
  anthropicVision.ts    Claude, direct API        ─── depends on a vendor SDK
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
registerAdapter('claude-opus', () =>
  createAnthropicVisionAdapter({
    id: 'claude-opus',
    label: 'Claude Opus 5.5',
    model: 'claude-opus-5-5',
  }),
);
```

A different Claude model is a different id. Verify ids against the live list —
ids recalled from memory are routinely stale:

```bash
curl -s https://api.anthropic.com/v1/models \
  -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
  | jq -r '.data[].id'
```

## Adding another provider

1. Write `src/adapters/<name>.ts` exporting something that satisfies
   `VisionAdapter` — use `anthropicVision.ts` as the shape.
2. Classify that provider's failures into `timeout` / `rate_limited` /
   `upstream`.
3. Add one `registerAdapter` line.

Nothing else changes: not the HTTP layer, not the contract, not the client.

Absorb a provider's quirks inside its adapter — a schema it does not enforce, a
"could not tell" it signals differently — and hand the rest of the service the
same shape every other provider hands it.

## Choosing which model answers

| Where          | How                                                   |
| -------------- | ----------------------------------------------------- |
| Per deployment | `RECOGNITION_ADAPTER` env var (default `claude-haiku`) |
| Per request    | `"adapter": "<id>"` in the request body, for A/B runs  |

Every adapter calls the Anthropic API directly, so **every deployment needs
`ANTHROPIC_API_KEY` set** — without it every request answers 502.
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
echo "ANTHROPIC_API_KEY=sk-ant-..." >> .env.local
npm run typecheck
npm test                         # contract, registry, and normalization
```

`npm test` covers everything except the provider call itself; hitting a real
model needs an Anthropic key.

## Privacy

Logs carry timings, outcome class, image byte count, and confidence — never the
image, the suggestion text, or anything the user typed. This mirrors the
allowlist the mobile client enforces on its own telemetry.
