from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import httpx

from app.schemas.enums import SourcePlatform

TRACKING_PARAM_PREFIXES = ("utm_", "ga_", "fb_", "mc_")
TRACKING_PARAMS = {
    "gclid", "fbclid", "yclid", "dclid", "msclkid",
    "igshid", "igsh", "si", "feature", "ref", "ref_src", "ref_url",
    "_hsenc", "_hsmi", "mkt_tok", "trk", "trkCampaign",
}

PLATFORM_HOST_MAP = {
    "instagram.com": SourcePlatform.instagram,
    "www.instagram.com": SourcePlatform.instagram,
    "linkedin.com": SourcePlatform.linkedin,
    "www.linkedin.com": SourcePlatform.linkedin,
    "youtube.com": SourcePlatform.youtube,
    "www.youtube.com": SourcePlatform.youtube,
    "m.youtube.com": SourcePlatform.youtube,
    "youtu.be": SourcePlatform.youtube,
    "twitter.com": SourcePlatform.x,
    "www.twitter.com": SourcePlatform.x,
    "x.com": SourcePlatform.x,
    "www.x.com": SourcePlatform.x,
    "tiktok.com": SourcePlatform.tiktok,
    "www.tiktok.com": SourcePlatform.tiktok,
    "vm.tiktok.com": SourcePlatform.tiktok,
    "vimeo.com": SourcePlatform.vimeo,
    "reddit.com": SourcePlatform.reddit,
    "www.reddit.com": SourcePlatform.reddit,
    "old.reddit.com": SourcePlatform.reddit,
}


def _strip_tracking(query: str) -> str:
    pairs = parse_qsl(query, keep_blank_values=True)
    kept = [
        (k, v)
        for k, v in pairs
        if k not in TRACKING_PARAMS and not any(k.startswith(p) for p in TRACKING_PARAM_PREFIXES)
    ]
    return urlencode(kept)


def normalize_url(url: str) -> str:
    parsed = urlparse(url.strip())
    scheme = (parsed.scheme or "https").lower()
    netloc = parsed.netloc.lower()
    if netloc.startswith("m."):
        netloc = netloc[2:]
    path = parsed.path.rstrip("/") or "/"
    query = _strip_tracking(parsed.query)
    return urlunparse((scheme, netloc, path, parsed.params, query, ""))


def detect_platform(url: str) -> SourcePlatform:
    host = urlparse(url).netloc.lower()
    return PLATFORM_HOST_MAP.get(host, SourcePlatform.web)


async def resolve_redirects(url: str, client: httpx.AsyncClient | None = None) -> str:
    """Follow HTTP redirects and return the final URL. Falls back to input on error."""
    own = client is None
    if own:
        client = httpx.AsyncClient(follow_redirects=True, timeout=10.0)
    try:
        try:
            resp = await client.head(url, follow_redirects=True)
            final = str(resp.url)
            if final and final != url:
                return final
        except httpx.HTTPError:
            pass
        try:
            resp = await client.get(url, follow_redirects=True)
            return str(resp.url)
        except httpx.HTTPError:
            return url
    finally:
        if own:
            await client.aclose()


async def canonicalize(source_url: str, client: httpx.AsyncClient | None = None) -> str:
    resolved = await resolve_redirects(source_url, client=client)
    return normalize_url(resolved)
