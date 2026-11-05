defmodule Foresight.TestSupport.Evals.HoldoutCorpus do
  @moduledoc """
  A held-out retrieval corpus for the honest held-out recall baseline.

  Design constraints that make it gaming-resistant:

    * **Unseen domain.** The content is a community-garden / allotment project — it shares
      no vocabulary with the old Oxford/Foresight/helios-diary eval corpus, and (enforced by
      `Foresight.Fitness.CorpusPurity`) none of these phrases appear in production or fake
      ranking code. A system cannot have been tuned to it.
    * **Labels on IDs, not text.** Relevance is graded per memory id (0 irrelevant …
      3 ideal). Scoring reads the ranked ids only, so emitting a corpus phrase earns
      nothing — only correct ordering does.
    * **Capability coverage.** Queries exercise the properties the gamed grader claimed:
      direct retrieval, paraphrase, supersession (corrected > stale), recency (latest >
      earlier), and distractor rejection (topically-near but wrong must not top-rank).

  `memories/0` are retained into a fresh bank; `queries/0` each carry a graded `relevance`
  map over those ids.
  """

  @doc "All memories to retain, in insertion order. Each has a stable string id."
  @spec memories() :: [map()]
  def memories do
    [
      %{
        "id" => "m_tomato_variety",
        "content" =>
          "For the north beds we chose the Marmande tomato because it sets fruit reliably in a cool, short season.",
        "context" => "notes",
        "mentioned_at" => "2026-03-01T09:00:00Z",
        "tags" => ["topic:planting", "bed:north"]
      },
      %{
        "id" => "m_tomato_reason_paraphrase",
        "content" =>
          "We picked Marmande for the shaded north plot mainly for its dependable fruiting when summers stay chilly.",
        "context" => "notes",
        "mentioned_at" => "2026-03-02T09:00:00Z",
        "tags" => ["topic:planting", "bed:north"]
      },
      %{
        "id" => "m_watering_initial",
        "content" => "Initial plan: water every bed daily at dawn through the whole season.",
        "context" => "chat",
        "mentioned_at" => "2026-03-05T08:00:00Z",
        "tags" => ["topic:watering", "status:superseded"]
      },
      %{
        "id" => "m_watering_corrected",
        "content" =>
          "Correction to the watering plan: daily watering waterlogged the clay beds, so we switched to deep watering twice a week.",
        "context" => "chat",
        "mentioned_at" => "2026-03-12T08:00:00Z",
        "tags" => ["topic:watering", "status:corrected"]
      },
      %{
        "id" => "m_compost_early",
        "content" =>
          "In April the compost bay was still cold and not breaking down; we were unsure it would be ready.",
        "context" => "chat",
        "mentioned_at" => "2026-04-10T08:00:00Z",
        "tags" => ["topic:compost"]
      },
      %{
        "id" => "m_compost_latest",
        "content" =>
          "Latest on compost: after turning it twice the bay is hot and crumbly, and it is ready to spread on the beds.",
        "context" => "chat",
        "mentioned_at" => "2026-06-20T08:00:00Z",
        "tags" => ["topic:compost", "status:latest"]
      },
      %{
        "id" => "m_slugs",
        "content" =>
          "Slugs took the young lettuce overnight, so we ringed the seedlings with crushed eggshell.",
        "context" => "notes",
        "mentioned_at" => "2026-05-02T08:00:00Z",
        "tags" => ["topic:pests"]
      },
      %{
        "id" => "m_bean_variety_distractor",
        "content" =>
          "For the climbing frame we chose the Cobra French bean for a long, tender pod harvest.",
        "context" => "notes",
        "mentioned_at" => "2026-03-03T09:00:00Z",
        "tags" => ["topic:planting", "bed:frame"]
      },
      %{
        "id" => "m_gate_repair",
        "content" =>
          "The allotment gate latch rusted through and was replaced with a galvanised bolt in May.",
        "context" => "notes",
        "mentioned_at" => "2026-05-15T08:00:00Z",
        "tags" => ["topic:maintenance"]
      },
      %{
        "id" => "m_rhubarb",
        "content" =>
          "The rhubarb crown we split last year has three strong crowns now and can be forced next spring.",
        "context" => "notes",
        "mentioned_at" => "2026-04-22T08:00:00Z",
        "tags" => ["topic:planting", "bed:corner"]
      }
    ]
  end

  @doc """
  Graded-relevance queries. `relevance` maps memory id → gain (0..3). Ids absent from the
  map are relevance 0 (irrelevant) by convention.
  """
  @spec queries() :: [map()]
  def queries do
    [
      %{
        id: "q_explicit_tomato",
        class: "explicit",
        query: "Which tomato variety did we choose for the north beds and why?",
        query_timestamp: "2026-07-01T12:00:00Z",
        relevance: %{
          "m_tomato_variety" => 3,
          "m_tomato_reason_paraphrase" => 2,
          "m_bean_variety_distractor" => 0,
          "m_rhubarb" => 0
        }
      },
      %{
        id: "q_paraphrase_tomato",
        class: "paraphrase",
        query: "Why did the shaded northern plot get Marmande plants?",
        query_timestamp: "2026-07-01T12:00:00Z",
        relevance: %{
          "m_tomato_reason_paraphrase" => 3,
          "m_tomato_variety" => 3,
          "m_bean_variety_distractor" => 0
        }
      },
      %{
        id: "q_superseded_watering",
        class: "superseded",
        query: "What is the correct watering schedule for the clay beds now?",
        query_timestamp: "2026-07-01T12:00:00Z",
        relevance: %{
          "m_watering_corrected" => 3,
          "m_watering_initial" => 1
        }
      },
      %{
        id: "q_recency_compost",
        class: "recency",
        query: "What is the current state of the compost — is it ready to use?",
        query_timestamp: "2026-07-01T12:00:00Z",
        relevance: %{
          "m_compost_latest" => 3,
          "m_compost_early" => 1
        }
      },
      %{
        id: "q_distractor_beans",
        class: "distractor",
        query: "Which climbing bean did we grow on the frame?",
        query_timestamp: "2026-07-01T12:00:00Z",
        relevance: %{
          "m_bean_variety_distractor" => 3,
          "m_tomato_variety" => 0,
          "m_rhubarb" => 0
        }
      },
      %{
        id: "q_explicit_pests",
        class: "explicit",
        query: "How did we protect the lettuce seedlings from slugs?",
        query_timestamp: "2026-07-01T12:00:00Z",
        relevance: %{
          "m_slugs" => 3
        }
      }
    ]
  end
end
