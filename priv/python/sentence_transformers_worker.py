from __future__ import annotations

import logging
import warnings
from collections import OrderedDict

# Loaded models, keyed by (kind, model name, force_cpu, trust_remote_code) and
# evicted least-recently-used. Banks may pin different embedders (per-bank
# `embed_model`), so a single slot would reload a model on every alternation;
# the caps bound resident memory when many models are in play.
_EMBEDDER_CACHE_SIZE = 4
_RERANKER_CACHE_SIZE = 2
_embedders: "OrderedDict[tuple, object]" = OrderedDict()
_rerankers: "OrderedDict[tuple, object]" = OrderedDict()


def _cache_get(cache, key):
    model = cache.get(key)
    if model is not None:
        cache.move_to_end(key)
    return model


def _cache_put(cache, key, model, size):
    cache[key] = model
    cache.move_to_end(key)
    while len(cache) > size:
        cache.popitem(last=False)
    return model


def _as_text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return str(value)


def _materialize_cpu_weights(module):
    """Copy CPU-resident parameters out of the loader's memory-mapped checkpoint.

    transformers 5.x leaves CPU weights backed by the mmapped safetensors file. On
    macOS/arm64 a forward pass over those tensors bus-faults or returns NaN for every
    input (seen with torch 2.10-2.13 and transformers 5.8-5.13 on
    cross-encoder/ms-marco-MiniLM-L-6-v2), while the same weights copied to MPS score
    correctly. Cloning them into ordinary tensors at load time removes the dependency;
    it costs one pass over the weights and nothing on GPU-resident models.
    """
    import torch

    with torch.no_grad():
        for param in module.parameters():
            if param.device.type == "cpu":
                param.data = param.data.clone().contiguous()
        for buf in module.buffers():
            if buf.device.type == "cpu":
                buf.data = buf.data.clone().contiguous()


def _model_device(module):
    try:
        return str(next(module.parameters()).device)
    except Exception:
        return "unknown"


def _ensure_finite(values, what, module):
    """Refuse to hand non-finite scores or vectors to the Elixir side.

    erlport cannot encode NaN at all (the call dies with invalid_protocol_data and takes
    the worker down); a bad score must surface as a clean error instead.
    """
    import math

    flat = values if not values or not isinstance(values[0], list) else [v for row in values for v in row]
    if any(not math.isfinite(v) for v in flat):
        raise RuntimeError(
            f"{what} produced non-finite values on device {_model_device(module)}; "
            "the model weights or the CPU inference path are broken"
        )
    return values


def _detect_device(force_cpu: bool):
    import torch

    if force_cpu:
        return "cpu"

    try:
        has_gpu = torch.cuda.is_available() or (
            hasattr(torch.backends, "mps") and torch.backends.mps.is_available()
        )
        if has_gpu:
            return None
    except Exception:
        pass

    return "cpu"


def _load_embedder(model_name: str, force_cpu: bool, trust_remote_code: bool):
    key = ("embedder", model_name, force_cpu, trust_remote_code)
    cached = _cache_get(_embedders, key)
    if cached is not None:
        return cached

    from sentence_transformers import SentenceTransformer

    device = _detect_device(force_cpu)

    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=UserWarning)
        warnings.filterwarnings("ignore", message=".*was not found in model state dict.*")
        warnings.filterwarnings("ignore", message=".*UNEXPECTED.*")

        transformers_logger = logging.getLogger("transformers")
        original_level = transformers_logger.level
        transformers_logger.setLevel(logging.ERROR)

        try:
            model = SentenceTransformer(
                model_name,
                device=device,
                model_kwargs={"low_cpu_mem_usage": False},
                trust_remote_code=trust_remote_code,
            )
        finally:
            transformers_logger.setLevel(original_level)

    _materialize_cpu_weights(model)
    return _cache_put(_embedders, key, model, _EMBEDDER_CACHE_SIZE)


def _load_reranker(model_name: str, force_cpu: bool, trust_remote_code: bool):
    key = ("reranker", model_name, force_cpu, trust_remote_code)
    cached = _cache_get(_rerankers, key)
    if cached is not None:
        return cached

    import torch
    from sentence_transformers import CrossEncoder

    device = _detect_device(force_cpu)

    # Score raw logits, whatever the model's own default is. CrossEncoder.predict
    # applies the model's default activation: Identity for e.g.
    # cross-encoder/ms-marco-MiniLM-L-6-v2, but Sigmoid for e.g.
    # BAAI/bge-reranker-v2-m3. The Elixir seam applies the one sigmoid that turns a
    # logit into rerank_score, so a model-side sigmoid would be applied twice and
    # squeeze every score into (0.5, 0.73): cutoffs at or below 0.5 keep everything
    # and strongly negative logits round to exactly 0.5. Pinning Identity here keeps
    # the contract: worker = logits. `activation_fn` and `model_kwargs` are the
    # sentence-transformers >= 4 constructor (pinned in priv/python/requirements.txt).
    kwargs = dict(
        device=device,
        model_kwargs={"low_cpu_mem_usage": False},
        trust_remote_code=trust_remote_code,
        activation_fn=torch.nn.Identity(),
    )

    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", category=UserWarning)
        warnings.filterwarnings("ignore", message=".*was not found in model state dict.*")
        warnings.filterwarnings("ignore", message=".*UNEXPECTED.*")

        transformers_logger = logging.getLogger("transformers")
        original_level = transformers_logger.level
        transformers_logger.setLevel(logging.ERROR)

        try:
            model = CrossEncoder(model_name, **kwargs)
        finally:
            transformers_logger.setLevel(original_level)

    _materialize_cpu_weights(getattr(model, "model", model))
    return _cache_put(_rerankers, key, model, _RERANKER_CACHE_SIZE)


def embedding_dimension(embedder_model_name, _reranker_model_name, force_cpu, trust_remote_code):
    try:
        model = _load_embedder(_as_text(embedder_model_name), bool(force_cpu), bool(trust_remote_code))
        # get_sentence_embedding_dimension was renamed to get_embedding_dimension in newer
        # sentence-transformers; fall back so we work across versions without a deprecation warning.
        dim_fn = getattr(model, "get_embedding_dimension", None) or model.get_sentence_embedding_dimension
        return ("ok", int(dim_fn()))
    except Exception as exc:
        return ("error", repr(exc))


def device_info(embedder_model_name, reranker_model_name, force_cpu, trust_remote_code):
    """Report the actual torch device each model loaded on, so callers can verify
    (not assume) that inference runs on the GPU (mps/cuda) rather than silently on CPU."""
    try:
        import torch

        emb = _load_embedder(_as_text(embedder_model_name), bool(force_cpu), bool(trust_remote_code))
        info = {"embedder_device": str(next(emb.parameters()).device)}

        try:
            rr = _load_reranker(_as_text(reranker_model_name), bool(force_cpu), bool(trust_remote_code))
            info["reranker_device"] = str(next(rr.model.parameters()).device)
            # The activation the worker scores with; must be Identity (raw logits)
            # for the Elixir seam's single sigmoid to be the only one.
            activation = getattr(rr, "activation_fn", None)
            if activation is None:
                activation = getattr(rr, "default_activation_function", None)
            info["reranker_activation"] = type(activation).__name__
        except Exception as exc:
            info["reranker_device"] = "error: " + repr(exc)

        info["mps_available"] = bool(
            hasattr(torch.backends, "mps") and torch.backends.mps.is_available()
        )
        info["cuda_available"] = bool(torch.cuda.is_available())
        return ("ok", info)
    except Exception as exc:
        return ("error", repr(exc))


def embed(text, embedder_model_name, _reranker_model_name, force_cpu, trust_remote_code):
    try:
        model = _load_embedder(_as_text(embedder_model_name), bool(force_cpu), bool(trust_remote_code))
        embeddings = model.encode([_as_text(text)], convert_to_numpy=True, show_progress_bar=False)
        return ("ok", _ensure_finite(embeddings[0].tolist(), "embedder", model))
    except Exception as exc:
        return ("error", repr(exc))


def embed_many(texts, embedder_model_name, _reranker_model_name, force_cpu, trust_remote_code):
    try:
        model = _load_embedder(_as_text(embedder_model_name), bool(force_cpu), bool(trust_remote_code))
        embeddings = model.encode(
            [_as_text(text) for text in texts],
            convert_to_numpy=True,
            show_progress_bar=False,
        )
        return ("ok", _ensure_finite([embedding.tolist() for embedding in embeddings], "embedder", model))
    except Exception as exc:
        return ("error", repr(exc))


def rerank(query, candidates, _embedder_model_name, reranker_model_name, force_cpu, trust_remote_code):
    try:
        model = _load_reranker(_as_text(reranker_model_name), bool(force_cpu), bool(trust_remote_code))
        pairs = [(_as_text(query), _as_text(candidate)) for candidate in candidates]
        scores = model.predict(pairs, show_progress_bar=False)
        if hasattr(scores, "tolist"):
            scores = scores.tolist()
        # A length-1 predict can squeeze to a bare scalar; always hand back a list
        # so the Elixir seam's per-candidate zip/count stays well-typed.
        if not isinstance(scores, list):
            scores = [scores]
        reranker = getattr(model, "model", model)
        return ("ok", _ensure_finite([float(score) for score in scores], "reranker", reranker))
    except Exception as exc:
        return ("error", repr(exc))


def _parse_reference(reference_iso):
    import datetime as _dt

    text = _as_text(reference_iso).strip() if reference_iso else ""
    if not text:
        return _dt.datetime.now()
    # Elixir hands us e.g. "2024-06-19T12:00:00Z"; make it naive (RETURN_AS_TIMEZONE_AWARE=False).
    text = text.replace("Z", "+00:00")
    try:
        return _dt.datetime.fromisoformat(text).replace(tzinfo=None)
    except Exception:
        return _dt.datetime.now()


# Common words dateparser mis-reads as dates; port of Hindsight's false-positive set
# (query_analyzer.py:160). A short token is kept only if the matched text is > 3 chars.
_DATE_FALSE_POSITIVES = {"do", "may", "march", "will", "can", "sat", "sun", "mon", "tue", "wed", "thu", "fri"}


def analyze_query(query, reference_iso, _embedder_model_name, _reranker_model_name, _force_cpu, _trust_remote_code):
    """Extract a single explicit/relative date from a query via dateparser (200+ langs).

    Mirrors Hindsight's DateparserQueryAnalyzer.analyze search_dates branch: returns the
    first valid date as an ISO date string (YYYY-MM-DD), or None. Period expressions are
    handled natively on the Elixir side (Foresight.Recall.QueryAnalyzer) BEFORE this is
    called, matching Hindsight's _extract_period-first ordering.
    """
    try:
        from dateparser.search import search_dates

        q = _as_text(query)
        settings = {
            "RELATIVE_BASE": _parse_reference(reference_iso),
            "PREFER_DATES_FROM": "past",
            "RETURN_AS_TIMEZONE_AWARE": False,
        }

        try:
            results = search_dates(q, settings=settings)
        except Exception:
            # dateparser has been observed to crash internally on some inputs; a parser
            # bug must not fail recall — treat as "no temporal constraint".
            return ("ok", None)

        if not results:
            return ("ok", None)

        # Accept ONLY matches whose text contains a digit — explicit/absolute dates in any
        # language (incl. Greek "15 Μαρτίου 2024", prose "March 3rd 2024", "3/15/2024").
        # This is a deliberate IMPROVEMENT over Hindsight's word-denylist filter, which
        # lets bare conjunctions/ordinals ("or", "first") parse as dates and spuriously
        # temporal-signal ordering/counting questions (the temporal-reasoning class we care
        # about). Relative period words (yesterday/last week, multilingual) are handled by
        # the native Elixir analyzer BEFORE this is called, so nothing real is lost.
        valid = [
            (text, dt)
            for (text, dt) in results
            if any(ch.isdigit() for ch in text) and text.lower() not in _DATE_FALSE_POSITIVES
        ]
        if not valid:
            return ("ok", None)

        _, parsed = valid[0]
        return ("ok", parsed.date().isoformat())
    except Exception as exc:
        return ("error", repr(exc))
