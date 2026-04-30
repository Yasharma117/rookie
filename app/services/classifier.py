"""LLM-backed link classifier.

Abstracted behind a Protocol so the OpenAI implementation can be swapped
for Anthropic (or any other provider) by changing one line in enrichment.py.
"""
import logging
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

        category_list = "\n".join(f"- {c.name}" for c in categories)
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
                            "If nothing fits well, choose 'Other'. "
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
        category_list = ", ".join(names)

        prompt = (
            f"Classify the link into exactly one of: {category_list}. "
            "If nothing fits well, choose 'Other'.\n\n"
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


def get_classifier() -> Classifier:
    if settings.gemini_api_key:
        return GeminiClassifier(
            api_key=settings.gemini_api_key, model=settings.gemini_model
        )
    if settings.openai_api_key.startswith("sk-"):
        return OpenAIClassifier(api_key=settings.openai_api_key)
    return FakeClassifier()
