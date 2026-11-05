import Config

config :foresight,
  auth: [
    api_key: nil
  ],
  engine: [
    storage: Foresight.Storage.Ecto,
    repo: Foresight.Repo,
    embedder: Foresight.Embedders.Noop,
    reranker: Foresight.Rerankers.Bumblebee,
    llm: Foresight.LLMs.LlmCore,
    queue: Foresight.AsyncQueues.Oban,
    oban_name: Foresight.Oban,
    reranker_serving_name: Foresight.ML.RerankerServing,
    provider: :"Elixir.LlmCore.LLM.Native",
    provider_opts: [],
    reflect_max_iterations: 10,
    reflect_min_grounding_count: 1,
    reflect_min_diverse_grounding_count: 1,
    reflect_min_provenance_cluster_count: 1,
    reflect_min_source_provenance_cluster_count: 0,
    reflect_min_source_family_count: 0,
    reflect_min_source_lineage_count: 0,
    reflect_min_evidence_family_count: 0,
    reflect_max_context_tokens: 100_000,
    reflect_timeout_ms: 120_000
  ],
  http: [
    enabled: false,
    ip: {127, 0, 0, 1},
    port: 4001,
    diagnostics: [
      enabled: false
    ]
  ],
  ml: [
    enabled: false,
    module: Foresight.ML.Serving,
    model_id: "BAAI/bge-small-en-v1.5",
    reranker_module: Foresight.ML.RerankerServing,
    reranker_model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2",
    reranker_serving_name: Foresight.ML.RerankerServing,
    output_attribute: :hidden_state,
    output_pool: :mean_pooling,
    embedding_processor: :l2_norm,
    serving_name: Foresight.ML.Serving
  ],
  tokenizer: [
    identifier: "Xenova/text-embedding-ada-002",
    path: nil,
    use_cache: true
  ],
  repo: [
    enabled: false
  ],
  oban: [
    enabled: false,
    module: Foresight.Oban,
    name: Foresight.Oban,
    peer: false,
    plugins: false,
    queues: [
      foresight_retain: 10,
      foresight_consolidate: 5,
      foresight_webhook_delivery: 5,
      foresight_embedding_backfill: 5,
      foresight_refresh_mental_model: 5,
      foresight_migrate_bank: 3,
      foresight_probe_bank: 3
    ]
  ],
  webhook_delivery: [
    http_client: Foresight.Webhooks.HttpcClient
  ],
  health: [
    checker: Foresight.Health
  ]

config :foresight, Foresight.Repo, types: Foresight.PostgrexTypes
config :foresight, Foresight.PublicRepo, types: Foresight.PostgrexTypes
