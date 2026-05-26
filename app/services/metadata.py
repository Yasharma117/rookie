from dataclasses import dataclass, field
from typing import Any
from urllib.parse import quote

import extruct
import httpx
from bs4 import BeautifulSoup

from app.schemas.enums import SourcePlatform

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 RookieBot/0.1"
)

OEMBED_PROVIDERS: dict[SourcePlatform, str] = {
    SourcePlatform.youtube: "https://www.youtube.com/oembed?url={url}&format=json",
    SourcePlatform.vimeo: "https://vimeo.com/api/oembed.json?url={url}",
}


@dataclass
class FetchedMetadata:
    title: str | None = None
    description: str | None = None
    author: str | None = None
    thumbnail_url: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)


def _meta(soup: BeautifulSoup, *names: str) -> str | None:
    for name in names:
        tag = soup.find("meta", property=name) or soup.find("meta", attrs={"name": name})
        if tag and tag.get("content"):
            return tag["content"].strip()
    return None


def _parse_html(html: str) -> FetchedMetadata:
    soup = BeautifulSoup(html, "html.parser")
    title = (
        _meta(soup, "og:title", "twitter:title")
        or (soup.title.string.strip() if soup.title and soup.title.string else None)
    )
    description = _meta(soup, "og:description", "twitter:description", "description")
    author = _meta(soup, "article:author", "author", "twitter:creator")
    thumb = _meta(soup, "og:image", "twitter:image", "twitter:image:src")
    raw = {
        "og:title": _meta(soup, "og:title"),
        "og:description": _meta(soup, "og:description"),
        "og:image": _meta(soup, "og:image"),
        "og:site_name": _meta(soup, "og:site_name"),
        "twitter:card": _meta(soup, "twitter:card"),
    }
    return FetchedMetadata(
        title=title, description=description, author=author, thumbnail_url=thumb, raw=raw
    )


def _parse_structured_data(html: str, base_url: str) -> FetchedMetadata | None:
    """Extract JSON-LD / microdata via extruct.

    Returns a FetchedMetadata if at least a title is found, otherwise None.
    Works especially well for recipe sites, news articles, and e-commerce pages
    that embed schema.org structured data — giving the classifier much richer signal
    than raw OG tags.
    """
    try:
        data = extruct.extract(
            html,
            base_url=base_url,
            syntaxes=["json-ld", "microdata"],
            uniform=True,
        )
    except Exception:
        return None

    for item in data.get("json-ld", []) + data.get("microdata", []):
        name = item.get("name") or item.get("headline")
        desc = item.get("description") or item.get("abstract")

        author_raw = item.get("author")
        author: str | None = None
        if isinstance(author_raw, dict):
            author = author_raw.get("name")
        elif isinstance(author_raw, list) and author_raw:
            first = author_raw[0]
            author = first.get("name") if isinstance(first, dict) else str(first)

        thumb = item.get("image") or item.get("thumbnailUrl")
        if isinstance(thumb, dict):
            thumb = thumb.get("url")
        elif isinstance(thumb, list) and thumb:
            first_thumb = thumb[0]
            thumb = first_thumb.get("url") if isinstance(first_thumb, dict) else str(first_thumb)

        if name:
            return FetchedMetadata(
                title=str(name),
                description=str(desc) if desc else None,
                author=author,
                thumbnail_url=str(thumb) if thumb else None,
                raw={"json-ld": item},
            )
    return None


async def _fetch_oembed(
    client: httpx.AsyncClient, platform: SourcePlatform, url: str
) -> FetchedMetadata | None:
    template = OEMBED_PROVIDERS.get(platform)
    if not template:
        return None
    endpoint = template.format(url=quote(url, safe=""))
    try:
        r = await client.get(endpoint, timeout=10.0)
        if r.status_code != 200:
            return None
        data = r.json()
    except (httpx.HTTPError, ValueError):
        return None
    return FetchedMetadata(
        title=data.get("title"),
        description=data.get("description"),
        author=data.get("author_name"),
        thumbnail_url=data.get("thumbnail_url"),
        raw={"oembed": data},
    )


async def fetch_metadata(
    url: str, platform: SourcePlatform, client: httpx.AsyncClient | None = None
) -> FetchedMetadata:
    own = client is None
    if own:
        client = httpx.AsyncClient(
            follow_redirects=True,
            timeout=15.0,
            headers={"User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9"},
        )
    try:
        oembed = await _fetch_oembed(client, platform, url)
        if oembed and oembed.title:
            return oembed

        try:
            r = await client.get(url)
            r.raise_for_status()
        except httpx.HTTPError:
            return FetchedMetadata()

        ctype = r.headers.get("content-type", "")
        if "html" not in ctype.lower():
            return FetchedMetadata()

        # Prefer structured data (JSON-LD / microdata) — richer than OG tags
        structured = _parse_structured_data(r.text, url)
        if structured and structured.title:
            return structured

        return _parse_html(r.text)
    finally:
        if own:
            await client.aclose()


async def download_thumbnail(
    url: str, client: httpx.AsyncClient | None = None
) -> tuple[bytes, str] | None:
    """Returns (bytes, content_type) or None on failure."""
    own = client is None
    if own:
        client = httpx.AsyncClient(
            follow_redirects=True, timeout=15.0, headers={"User-Agent": USER_AGENT}
        )
    try:
        try:
            r = await client.get(url)
            r.raise_for_status()
        except httpx.HTTPError:
            return None
        ctype = r.headers.get("content-type", "image/jpeg").split(";")[0].strip()
        if not ctype.startswith("image/"):
            return None
        return r.content, ctype
    finally:
        if own:
            await client.aclose()
