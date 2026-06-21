"""Extracts the clean article body from raw HTML using trafilatura.

Returns (body_text, word_count). Callers use the word count to decide whether
the link qualifies as long-form text content worth summarizing.
"""
from __future__ import annotations

import logging

import trafilatura

logger = logging.getLogger(__name__)

# Below this word count we consider the page too short to bother summarizing —
# OG-style teaser pages, link aggregator hubs, single-paragraph blurbs, etc.
ARTICLE_MIN_WORDS = 400


def extract_body(html: str, url: str | None = None) -> tuple[str | None, int]:
    """Pull main article text out of `html`.

    Returns (body_text, word_count). `body_text` is None when trafilatura
    couldn't find a meaningful body. `word_count` is 0 in that case.
    """
    if not html:
        return None, 0

    try:
        body = trafilatura.extract(
            html,
            url=url,
            include_comments=False,
            include_tables=False,
            include_images=False,
            include_links=False,
            favor_precision=True,
            output_format="txt",
        )
    except Exception as exc:
        logger.warning('"event":"trafilatura_fail","url":"%s","error":"%s"', url, exc)
        return None, 0

    if not body:
        return None, 0

    word_count = len(body.split())
    return body, word_count


def qualifies_as_article(word_count: int) -> bool:
    """Threshold check — returns True if the body is long-form enough to summarize."""
    return word_count >= ARTICLE_MIN_WORDS
