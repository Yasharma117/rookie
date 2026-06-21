"""LLM-backed article summarizer.

Produces a structured "summary_segments" array: a single composed sentence
broken into ordered text segments, with three of them tagged emphasis=1/2/3
to mark the load-bearing key phrases.

Mirrors the Classifier protocol pattern: production uses OpenRouter's
waterfall, dev/test fallback returns None so the article card simply
isn't shown.
"""
from __future__ import annotations

import json
import logging
import time
from typing import Any, Protocol

from openai import AsyncOpenAI
from pydantic import BaseModel, ValidationError

from app.config import settings

logger = logging.getLogger(__name__)

# Trim very long bodies before sending to the LLM — the first ~2000 words
# are nearly always sufficient to capture the thesis.
_MAX_BODY_WORDS = 2000


class SummarySegment(BaseModel):
    text: str
    emphasis: int | None = None  # None for connective tissue, 1/2/3 for the key phrases


class _SummaryResponse(BaseModel):
    summary_segments: list[SummarySegment]


def _trim_body(body: str) -> str:
    words = body.split()
    if len(words) <= _MAX_BODY_WORDS:
        return body
    return " ".join(words[:_MAX_BODY_WORDS])


def _validate_segments(segments: list[SummarySegment]) -> list[dict[str, Any]] | None:
    """Sanity-check the structure: exactly 3 emphasized segments in order 1,2,3."""
    if not segments:
        return None
    emphasized = [s.emphasis for s in segments if s.emphasis is not None]
    if emphasized != [1, 2, 3]:
        logger.warning(
            '"event":"summary_invalid","reason":"bad_emphasis_order","got":%s',
            emphasized,
        )
        return None
    if not any(s.emphasis is None for s in segments):
        # Connective tissue is what makes the sentence read naturally; if the LLM
        # produced only emphasized segments the result will look like a bullet list.
        logger.warning('"event":"summary_invalid","reason":"no_connective"')
        return None
    return [s.model_dump() for s in segments]


_SYSTEM_BASE = (
    "You write a single natural-reading sentence that summarizes an article. "
    "The sentence is split into ordered segments. Exactly THREE segments are "
    "emphasized (emphasis = 1, 2, 3 in reading order). Each emphasized segment "
    "is one load-bearing phrase capturing a key idea from the article. "
    "Between the emphasized phrases, include connective grammar segments "
    "(emphasis = null) so the segments concatenated together read as one "
    "natural English sentence. The full sentence must be at most 40 words "
    "and stand alone: a reader skimming only the three emphasized phrases "
    "should still get the gist."
)

_REGENERATE_HINT = (
    "\n\nIMPORTANT: produce a DIFFERENT framing from what a generic summarizer "
    "would write. Pick a different angle or emphasize different aspects of the "
    "article — do not paraphrase prior summaries."
)


class Summarizer(Protocol):
    async def summarize(
        self,
        title: str | None,
        article_body: str,
        alternate_framing: bool = False,
    ) -> list[dict[str, Any]] | None: ...


class FakeSummarizer:
    async def summarize(
        self,
        title: str | None,
        article_body: str,
        alternate_framing: bool = False,
    ) -> list[dict[str, Any]] | None:
        return None


class OpenRouterSummarizer:
    """Multi-model waterfall via OpenRouter (mirrors OpenRouterClassifier)."""

    _FALLBACK_MODELS = [
        "google/gemini-2.5-flash",
        "openai/gpt-4o-mini",
        "meta-llama/llama-3.3-70b-instruct",
    ]

    def __init__(self, api_key: str) -> None:
        self._client = AsyncOpenAI(
            base_url="https://openrouter.ai/api/v1",
            api_key=api_key,
            default_headers={
                "HTTP-Referer": "https://becauseyssaidso.app",
                "X-Title": "Rookie Article Summarizer",
            },
        )

    async def summarize(
        self,
        title: str | None,
        article_body: str,
        alternate_framing: bool = False,
    ) -> list[dict[str, Any]] | None:
        t0 = time.monotonic()
        body = _trim_body(article_body)
        system = _SYSTEM_BASE + (_REGENERATE_HINT if alternate_framing else "")
        user = (
            f"Title: {title or '(missing)'}\n\n"
            f"Article body:\n{body}"
        )
        schema = {
            "type": "object",
            "properties": {
                "summary_segments": {
                    "type": "array",
                    "minItems": 4,  # at least 3 emphasized + 1 connective
                    "maxItems": 12,
                    "items": {
                        "type": "object",
                        "properties": {
                            "text": {"type": "string", "minLength": 1},
                            "emphasis": {"type": ["integer", "null"], "enum": [1, 2, 3, None]},
                        },
                        "required": ["text", "emphasis"],
                        "additionalProperties": False,
                    },
                },
            },
            "required": ["summary_segments"],
            "additionalProperties": False,
        }

        try:
            resp = await self._client.chat.completions.create(
                model=self._FALLBACK_MODELS[0],
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                response_format={
                    "type": "json_schema",
                    "json_schema": {
                        "name": "article_summary",
                        "strict": True,
                        "schema": schema,
                    },
                },
                max_tokens=400,
                timeout=12.0,
                extra_body={
                    "models": self._FALLBACK_MODELS,
                    "provider": {
                        "sort": "latency",
                        "require_parameters": True,
                        "allow_fallbacks": True,
                    },
                    "plugins": [{"id": "response-healing"}],
                },
            )
            raw = json.loads(resp.choices[0].message.content)
            parsed = _SummaryResponse.model_validate(raw)
        except (json.JSONDecodeError, ValidationError) as e:
            logger.warning("Summarizer parse failed: %s: %s", type(e).__name__, e)
            return None
        except Exception as e:
            logger.warning("Summarizer failed: %s: %s", type(e).__name__, e)
            return None

        validated = _validate_segments(parsed.summary_segments)
        ms = int((time.monotonic() - t0) * 1000)
        logger.info(
            '"event":"summarize_ok","provider":"openrouter","ms":%d,"valid":%s',
            ms,
            validated is not None,
        )
        return validated


def get_summarizer() -> Summarizer:
    if settings.openrouter_api_key:
        return OpenRouterSummarizer(api_key=settings.openrouter_api_key)
    return FakeSummarizer()
