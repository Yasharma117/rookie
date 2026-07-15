import re
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

# Instagram serves a login wall to normal browser/bot UAs, but returns the Open
# Graph tags (incl. og:image) to the Facebook link-preview crawler — the same
# path iMessage/WhatsApp/Slack previews use. The og:image is a signed,
# short-lived scontent.cdninstagram.com URL, so callers MUST mirror it to object
# storage promptly; hotlinking it breaks within days.
CRAWLER_USER_AGENT = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"

# Platforms that gate metadata behind the crawler UA above.
_CRAWLER_UA_PLATFORMS: set[SourcePlatform] = {SourcePlatform.instagram}

OEMBED_PROVIDERS: dict[SourcePlatform, str] = {
    SourcePlatform.youtube: "https://www.youtube.com/oembed?url={url}&format=json",
    SourcePlatform.vimeo: "https://vimeo.com/api/oembed.json?url={url}",
}

# YouTube oEmbed returns the 4:3 hqdefault.jpg (and sd/mqdefault variants), which
# for most videos is a 16:9 frame letterboxed with baked-in black bars. maxresdefault
# is the clean, bar-free 16:9 frame, available for essentially all HD uploads; a rare
# miss 404s and the client falls back to the generated poster. Vimeo/other hosts don't
# use this filename scheme, so the pattern leaves them untouched.
_YT_THUMB_RE = re.compile(r"/(?:hq|sd|mq)default\.jpg")


def upgrade_youtube_thumbnail(url: str | None) -> str | None:
    if not url:
        return url
    return _YT_THUMB_RE.sub("/maxresdefault.jpg", url)


@dataclass
class FetchedMetadata:
    title: str | None = None
    description: str | None = None
    author: str | None = None
    thumbnail_url: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)
    # Raw HTML of the page, populated when we actually fetched HTML (vs. oembed-only).
    # Reused by the article-body extractor to avoid a second HTTP request.
    html: str | None = None
    # Final URL after following redirects — used to (re)canonicalize the link
    # in enrichment, since the POST path no longer resolves redirects.
    final_url: str | None = None


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
        "twitter:image": _meta(soup, "twitter:image", "twitter:image:src"),
    }
    return FetchedMetadata(
        title=title,
        description=description,
        author=author,
        thumbnail_url=thumb,
        raw=raw,
        html=html,
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
    thumb = data.get("thumbnail_url")
    if platform is SourcePlatform.youtube:
        thumb = upgrade_youtube_thumbnail(thumb)
    return FetchedMetadata(
        title=data.get("title"),
        description=data.get("description"),
        author=data.get("author_name"),
        thumbnail_url=thumb,
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

        # Some platforms (Instagram) only reveal OG tags to the FB preview
        # crawler UA; override just this request so the shared client's default
        # UA still applies everywhere else.
        get_headers = (
            {"User-Agent": CRAWLER_USER_AGENT}
            if platform in _CRAWLER_UA_PLATFORMS
            else None
        )
        try:
            r = await client.get(url, headers=get_headers)
            r.raise_for_status()
        except httpx.HTTPError:
            return FetchedMetadata()

        final_url = str(r.url)
        ctype = r.headers.get("content-type", "")
        if "html" not in ctype.lower():
            return FetchedMetadata(final_url=final_url)

        # Prefer structured data (JSON-LD / microdata) — richer than OG tags
        structured = _parse_structured_data(r.text, url)
        if structured and structured.title:
            structured.html = r.text
            structured.final_url = final_url
            return structured

        parsed = _parse_html(r.text)
        parsed.final_url = final_url
        return parsed
    finally:
        if own:
            await client.aclose()


# Hosts that serve signed, short-lived URLs (Instagram/Facebook CDNs). These
# expire within days, so they're only usable once mirrored to our own storage —
# never as a hotlink fallback, which would show a briefly-working, then-broken
# image. Returning None here keeps such links thumbnail-less until storage is
# configured and the mirror path can capture them durably.
_EPHEMERAL_THUMB_HOSTS = ("cdninstagram.com", "fbcdn.net")


def _durable_or_none(url: str | None) -> str | None:
    if not url:
        return None
    return None if any(h in url for h in _EPHEMERAL_THUMB_HOSTS) else url


def remote_thumbnail_url(raw: dict[str, Any] | None) -> str | None:
    """Recover the source-page thumbnail URL from a link's stored raw_metadata.

    Serves as the API-level fallback when no thumbnail was mirrored to object
    storage (e.g. S3 unconfigured in the deployment) — covers all three raw
    shapes we persist: oembed, OG/twitter tags, and JSON-LD. Ephemeral signed
    CDN URLs are dropped, since hotlinking them would break within days.
    """
    if not raw:
        return None

    oembed = raw.get("oembed")
    if isinstance(oembed, dict) and oembed.get("thumbnail_url"):
        return _durable_or_none(upgrade_youtube_thumbnail(str(oembed["thumbnail_url"])))

    for tag in ("og:image", "twitter:image"):
        if raw.get(tag):
            return _durable_or_none(str(raw[tag]))

    item = raw.get("json-ld")
    if isinstance(item, dict):
        thumb = item.get("image") or item.get("thumbnailUrl")
        if isinstance(thumb, dict):
            thumb = thumb.get("url")
        elif isinstance(thumb, list) and thumb:
            first = thumb[0]
            thumb = first.get("url") if isinstance(first, dict) else first
        if thumb:
            return _durable_or_none(str(thumb))
    return None


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
