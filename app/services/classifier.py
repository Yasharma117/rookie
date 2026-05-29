"""LLM-backed link classifier.

Abstracted behind a Protocol so the implementation can be swapped
by changing one line in enrichment.py.

Classifier priority (get_classifier):
  1. OpenRouterClassifier  — if OPENROUTER_API_KEY is set
     Multi-model waterfall: gemini-2.0-flash:nitro → gpt-4.1-nano → llama-3.3-70b
     Uses OpenRouter's native model fallback (one HTTP request, server-side failover).
  2. GeminiClassifier      — if GEMINI_API_KEY is set
  3. OpenAIClassifier      — if OPENAI_API_KEY looks valid
  4. FakeClassifier        — dev fallback, always returns Other
"""
import json
import logging
import time
from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

import httpx
from openai import AsyncOpenAI
from pydantic import BaseModel, Field

from app.config import settings

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class CategoryChoice:
    id: UUID
    name: str
    description: str | None = None


def _format_categories(categories: list[CategoryChoice]) -> str:
    """Render categories as a bulleted list with descriptions for the LLM."""
    lines = []
    for c in categories:
        if c.description:
            lines.append(f"- {c.name}: {c.description}")
        else:
            lines.append(f"- {c.name}")
    return "\n".join(lines)


@dataclass
class ClassificationResult:
    category_id: UUID
    confidence: float
    reason: str


class Classifier(Protocol):
    async def classify(
        self,
        title: str | None,
        description: str | None,
        source_platform: str,
        categories: list[CategoryChoice],
    ) -> ClassificationResult: ...


class _LLMResponse(BaseModel):
    category_name: str = Field(description="Exact name from the provided category list")
    confidence: float = Field(ge=0.0, le=1.0)
    reason: str = Field(max_length=500)


class OpenAIClassifier:
    def __init__(self, api_key: str, model: str = "gpt-4o-mini") -> None:
        self._client = AsyncOpenAI(api_key=api_key)
        self._model = model

    async def classify(
        self,
        title: str | None,
        description: str | None,
        source_platform: str,
        categories: list[CategoryChoice],
    ) -> ClassificationResult:
        by_name = {c.name: c.id for c in categories}
        other_id = by_name.get("Other") or next(iter(by_name.values()))

        category_list = _format_categories(categories)
        content = (
            f"Title: {title or '(missing)'}\n"
            f"Description: {description or '(missing)'}\n"
            f"Source platform: {source_platform}"
        )

        try:
            resp = await self._client.responses.parse(
                model=self._model,
                input=[
                    {
                        "role": "system",
                        "content": (
                            "Classify the link into exactly one of the user's categories. "
                            "Each category includes a description of what it covers. "
                            "Pick the category whose description best fits the link. "
                            "If nothing fits well, choose 'Other'.\n\n"
                            f"Available categories:\n{category_list}"
                        ),
                    },
                    {"role": "user", "content": content},
                ],
                text_format=_LLMResponse,
            )
            parsed = resp.output_parsed
        except Exception as e:
            logger.warning("OpenAI classifier failed: %s: %s", type(e).__name__, e)
            return ClassificationResult(
                category_id=other_id, confidence=0.0, reason="classifier error"
            )

        if parsed is None:
            return ClassificationResult(
                category_id=other_id, confidence=0.0, reason="no parse"
            )

        chosen_id = by_name.get(parsed.category_name, other_id)
        return ClassificationResult(
            category_id=chosen_id, confidence=parsed.confidence, reason=parsed.reason
        )


class GeminiClassifier:
    """Google Gemini classifier via Generative Language API.

    Uses responseSchema for structured JSON output — no SDK dependency.
    """

    def __init__(self, api_key: str, model: str = "gemini-flash-latest") -> None:
        self._api_key = api_key
        self._model = model
        self._url = (
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        )

    async def classify(
        self,
        title: str | None,
        description: str | None,
        source_platform: str,
        categories: list[CategoryChoice],
    ) -> ClassificationResult:
        by_name = {c.name: c.id for c in categories}
        other_id = by_name.get("Other") or next(iter(by_name.values()))
        names = [c.name for c in categories]
        category_list = _format_categories(categories)

        prompt = (
            "Classify the link into exactly one of the categories below. "
            "Each category has a description of what it covers — pick the one "
            "whose description best fits the link. If nothing fits well, choose 'Other'.\n\n"
            f"Available categories:\n{category_list}\n\n"
            f"Title: {title or '(missing)'}\n"
            f"Description: {description or '(missing)'}\n"
            f"Source platform: {source_platform}"
        )

        body = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseSchema": {
                    "type": "object",
                    "properties": {
                        "category_name": {"type": "string", "enum": names},
                        "confidence": {"type": "number"},
                        "reason": {"type": "string"},
                    },
                    "required": ["category_name", "confidence", "reason"],
                },
            },
        }

        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                r = await client.post(
                    self._url, params={"key": self._api_key}, json=body
                )
                r.raise_for_status()
                data = r.json()
            text = data["candidates"][0]["content"]["parts"][0]["text"]
            parsed = _LLMResponse.model_validate_json(text)
        except Exception as e:
            logger.warning("Gemini classifier failed: %s: %s", type(e).__name__, e)
            return ClassificationResult(
                category_id=other_id, confidence=0.0, reason="classifier error"
            )

        chosen_id = by_name.get(parsed.category_name, other_id)
        return ClassificationResult(
            category_id=chosen_id, confidence=parsed.confidence, reason=parsed.reason
        )


class FakeClassifier:
    """Deterministic stub for tests / dev without an API key."""

    async def classify(
        self,
        title: str | None,
        description: str | None,
        source_platform: str,
        categories: list[CategoryChoice],
    ) -> ClassificationResult:
        other = next((c for c in categories if c.name == "Other"), categories[0])
        return ClassificationResult(category_id=other.id, confidence=0.0, reason="fake")


class OpenRouterClassifier:
    """Multi-model waterfall via OpenRouter's native model fallback.

    Fallback order (handled server-side by OpenRouter — single HTTP request):
      1. google/gemini-2.0-flash:nitro  — fastest routing, ~300ms TTFT
      2. openai/gpt-4.1-nano            — reliable JSON schema adherence
      3. meta-llama/llama-3.3-70b-instruct  — open-source, near-zero cost fallback

    Uses response-healing plugin to auto-fix malformed JSON.
    Uses require_parameters=True so only providers supporting json_schema are used.
    """

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
                "X-Title": "Rookie Link Classifier",
            },
        )

    async def classify(
        self,
        title: str | None,
        description: str | None,
        source_platform: str,
        categories: list[CategoryChoice],
    ) -> ClassificationResult:
        t0 = time.monotonic()
        by_name = {c.name: c.id for c in categories}
        other_id = by_name.get("Other") or next(iter(by_name.values()))

        category_list = _format_categories(categories)
        names = [c.name for c in categories]
        content = (
            f"Title: {title or '(missing)'}\n"
            f"Description: {description or '(missing)'}\n"
            f"Source platform: {source_platform}"
        )
        schema = {
            "type": "object",
            "properties": {
                "category_name": {"type": "string", "enum": names},
                "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                "reason": {"type": "string", "maxLength": 300},
            },
            "required": ["category_name", "confidence", "reason"],
            "additionalProperties": False,
        }

        try:
            resp = await self._client.chat.completions.create(
                model=self._FALLBACK_MODELS[0],  # primary; OR handles fallback
                messages=[
                    {
                        "role": "system",
                        "content": (
                            "Classify the link into exactly one of the user's categories. "
                            "Each category includes a description of what it covers. "
                            "Pick the category whose description best fits the link. "
                            "If nothing fits well, choose 'Other'.\n\n"
                            f"Available categories:\n{category_list}"
                        ),
                    },
                    {"role": "user", "content": content},
                ],
                response_format={
                    "type": "json_schema",
                    "json_schema": {
                        "name": "classification_result",
                        "strict": True,
                        "schema": schema,
                    },
                },
                max_tokens=100,
                timeout=8.0,
                extra_body={
                    "models": self._FALLBACK_MODELS,  # native OR fallback chain
                    "provider": {
                        "sort": "latency",
                        "require_parameters": True,  # json_schema-capable providers only
                        "allow_fallbacks": True,
                    },
                    "plugins": [{"id": "response-healing"}],  # auto-fix malformed JSON
                },
            )
            raw = json.loads(resp.choices[0].message.content)
            chosen_id = by_name.get(raw["category_name"], other_id)
            ms = int((time.monotonic() - t0) * 1000)
            logger.info(
                '"event":"classify_ok","provider":"openrouter","ms":%d,"confidence":%.2f',
                ms, raw["confidence"]
            )
            return ClassificationResult(
                category_id=chosen_id,
                confidence=raw["confidence"],
                reason=raw.get("reason", ""),
            )
        except Exception as e:
            logger.warning("OpenRouter classifier failed: %s: %s", type(e).__name__, e)
            return ClassificationResult(
                category_id=other_id, confidence=0.0, reason="classifier error"
            )


def get_classifier() -> Classifier:
    if settings.openrouter_api_key:
        return OpenRouterClassifier(api_key=settings.openrouter_api_key)
    if settings.gemini_api_key:
        return GeminiClassifier(
            api_key=settings.gemini_api_key, model=settings.gemini_model
        )
    if settings.openai_api_key.startswith("sk-"):
        return OpenAIClassifier(api_key=settings.openai_api_key)
    return FakeClassifier()
