"""
Docling wrapper for ErlPort integration.

Returns both a flattened markdown view (backward compatible) and, when docling
exposes document structure, a list of structural `chunks` carrying provenance
(page, section path, element type, bounding box, char span). The Elixir side turns
each chunk into a memory unit with a `source_location`, so an answer can be traced
back to the exact place in the source document. Structure extraction is best-effort
and degrades to markdown-only if the docling API differs.
"""

from pathlib import Path

try:
    from docling.document_converter import DocumentConverter
except ImportError:
    DocumentConverter = None


def _convert_path(file_path_input):
    if isinstance(file_path_input, bytes):
        return file_path_input.decode("utf-8")
    if isinstance(file_path_input, list):
        return "".join(chr(c) for c in file_path_input)
    return str(file_path_input)


def _bbox_of(prov_item):
    bbox = getattr(prov_item, "bbox", None)
    if bbox is None:
        return None
    return {
        "l": getattr(bbox, "l", None),
        "t": getattr(bbox, "t", None),
        "r": getattr(bbox, "r", None),
        "b": getattr(bbox, "b", None),
    }


def _item_text(item, document):
    text = getattr(item, "text", None)
    if text:
        return str(text)
    # Tables / structured items: try a markdown export in a version-tolerant way.
    exporter = getattr(item, "export_to_markdown", None)
    if callable(exporter):
        for args in ((document,), ()):
            try:
                out = exporter(*args)
                if out and str(out).strip():
                    return str(out)
            except Exception:
                continue
    return None


def _structural_chunks(document):
    chunks = []
    try:
        items = list(document.iterate_items())
    except Exception:
        return chunks

    section_stack = []  # list of (level, title)

    for entry in items:
        try:
            if isinstance(entry, tuple):
                item = entry[0]
                level = entry[1] if len(entry) > 1 else 0
            else:
                item, level = entry, 0

            label = str(getattr(item, "label", "") or "").lower()
            text = _item_text(item, document)
            if not text or not text.strip():
                continue

            if any(k in label for k in ("header", "title", "section")):
                while section_stack and section_stack[-1][0] >= level:
                    section_stack.pop()
                section_stack.append((level, text.strip()))

            page = None
            bbox = None
            char_start = None
            char_end = None
            prov = getattr(item, "prov", None) or []
            if prov:
                first = prov[0]
                page = getattr(first, "page_no", None)
                bbox = _bbox_of(first)
                span = getattr(first, "charspan", None)
                if span and len(span) == 2:
                    char_start, char_end = int(span[0]), int(span[1])

            chunks.append(
                {
                    "text": text,
                    "element_type": label or "text",
                    "page": page,
                    "section_path": [title for (_lvl, title) in section_stack],
                    "bbox": bbox,
                    "char_start": char_start,
                    "char_end": char_end,
                }
            )
        except Exception:
            continue

    return chunks


def parse_with_metadata(file_path_input):
    if DocumentConverter is None:
        return ("error", "Docling is not installed")

    try:
        file_path = _convert_path(file_path_input)
        converter = DocumentConverter()
        result = converter.convert(file_path)
        document = result.document
        markdown = document.export_to_markdown()
        chunks = _structural_chunks(document)
        metadata = {
            "title": getattr(document, "title", Path(file_path).stem),
            "format": Path(file_path).suffix.lower(),
        }
        return ("ok", {"markdown": markdown, "metadata": metadata, "chunks": chunks})
    except FileNotFoundError as exc:
        return ("error", f"File not found: {exc}")
    except Exception as exc:
        return ("error", f"Parsing failed: {exc}")
