# Development

Maintainer-facing workflows. Consumers do not need any of this — see the
[README](README.md) and [READINESS.md](READINESS.md) instead.

## Test lanes

Default `mix test` excludes the heavier parity lanes.

```bash
# Real-Postgres integration lane
FORESIGHT_TEST_INCLUDE_TAGS=tier2 mix test

# Full parity lane set
FORESIGHT_TEST_INCLUDE_TAGS=tier2,nightly mix test

# Opt-in ML lane: BAAI/bge-small-en-v1.5 Bumblebee serving smoke test, and the
# cl100k_base parity corpus through Foresight.Tokenizers.Cl100kBase
FORESIGHT_TEST_INCLUDE_TAGS=ml mix test

# Pin the tokenizer artifact explicitly instead of the Hugging Face default
FORESIGHT_CL100K_TOKENIZER_PATH=/abs/path/to/tokenizer.json \
FORESIGHT_TEST_INCLUDE_TAGS=ml mix test

# Benchmark/eval lane (LongMemEval and friends; hours-long, needs fetched data and,
# for the judge evals, live models). Excluded by default, and by the ml lane above.
FORESIGHT_TEST_INCLUDE_TAGS=eval mix test test/foresight/evals/longmemeval_recall_eval_test.exs
```

## Full ML authority

For local qualification with real embeddings, reranking, and live reflect wiring:

```bash
./scripts/start-foresight-full-ml-authority.sh
```

Defaults (all overridable via environment):

- `FORESIGHT_LOCAL_ML_BACKEND=sentence_transformers`
- `FORESIGHT_ML_PYTHON=python3` — must point at a Python 3 interpreter with
  `sentence-transformers` installed; typically the venv from a Hindsight
  checkout, e.g. `<hindsight>/.venv/bin/python3`
- `FORESIGHT_PRELOAD_LOCAL_MODELS=1` — warms the embedder, reranker, and
  tokenizer during boot so first live retain/recall requests do not pay
  model-load latency
- `FORESIGHT_PORT=4012`
- `FORESIGHT_DATABASE_URL=postgresql://postgres:postgres@localhost:5432/foresight_full_ml_authority_dev`

`sentence_transformers` through PyTorch is the fast local path on Apple Silicon;
the Bumblebee/EXLA lane is slower.

Useful overrides:

```bash
FORESIGHT_LOCAL_ML_BACKEND=bumblebee \
FORESIGHT_LLM_PROVIDER=openai \
FORESIGHT_LLM_BASE_URL=https://openrouter.ai/api/v1 \
FORESIGHT_LLM_API_KEY=... \
FORESIGHT_LLM_MODEL=openai/gpt-4.1-mini \
./scripts/start-foresight-full-ml-authority.sh
```

```bash
FORESIGHT_LOCAL_ML_BACKEND=sentence_transformers \
FORESIGHT_ML_PYTHON=/path/to/venv/bin/python3 \
FORESIGHT_PRELOAD_LOCAL_MODELS=0 \
FORESIGHT_LLM_BASE_URL=http://127.0.0.1:1234/v1 \
FORESIGHT_LLM_API_KEY=lm-studio \
FORESIGHT_LLM_MODEL=qwen3-8b \
./scripts/start-foresight-full-ml-authority.sh
```

Benchmark the configured retain/recall path with trace timings:

```bash
FORESIGHT_LOCAL_ML_BACKEND=sentence_transformers \
FORESIGHT_ML_PYTHON=/path/to/venv/bin/python3 \
mix run scripts/benchmark-foresight-memory.exs
```

This prints wall-clock time plus the traced `timings_ms` breakdown for each
retain/recall iteration — the quickest way to compare backends or hosts.

## Contract fixtures

The default self-consistency gate asserts live-backed FLOOR endpoints against
`priv/foresight/fixtures/recorded_floor_contract/`. The older
`priv/foresight/fixtures/floor_contract/` set remains only for synthetic operation
fixtures that are not emitted by the live recorder.

For occasional live-fixture capture, use the local launcher instead of starting
`uv run hindsight-api` by hand:

```bash
./scripts/start-hindsight-fixture-authority.sh
```

It starts a single-key local Hindsight authority on `127.0.0.1:8888` with
port/pid/zombie guards and a startup health probe. It expects a Hindsight
checkout containing `hindsight-api/` — by default the sibling `hindsight/`
directory next to this repository, overridable via `HINDSIGHT_ROOT`. It creates a
scratch Postgres database (`foresight_hindsight_dev`) if possible, and prefers
OpenRouter when `OPENROUTER_API_KEY` is present; otherwise it falls back to
LMStudio at `http://127.0.0.1:1234/v1`.

Useful overrides:

```bash
HINDSIGHT_USE_LMSTUDIO=1 ./scripts/start-hindsight-fixture-authority.sh
HINDSIGHT_ROOT=/abs/path/to/hindsight ./scripts/start-hindsight-fixture-authority.sh
HINDSIGHT_FIXTURE_API_KEY=my-dev-key ./scripts/start-hindsight-fixture-authority.sh
```

Refresh the recorded set from a `hindsight 0.7.1` authority with:

```bash
HINDSIGHT_FIXTURE_BASE_URL=http://127.0.0.1:8888 \
HINDSIGHT_FIXTURE_API_KEY=... \
mix foresight.record_floor_fixtures
```

The recorder seeds a small bank for the read/recall fixtures and updates
`manifest.json` next to the captured JSON bodies in `recorded_floor_contract/`.
