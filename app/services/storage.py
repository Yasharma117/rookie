import asyncio
from uuid import uuid4

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError

from app.config import settings


def _client():
    return boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint_url,
        aws_access_key_id=settings.s3_access_key,
        aws_secret_access_key=settings.s3_secret_key,
        region_name=settings.s3_region,
        # Path-style (host/bucket/key) is required by Supabase Storage and MinIO;
        # the default virtual-host style (bucket.host) doesn't resolve for them.
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def ensure_bucket() -> None:
    """Idempotent bucket creation — used for local MinIO bootstrap."""
    s3 = _client()
    try:
        s3.head_bucket(Bucket=settings.s3_bucket)
    except ClientError:
        s3.create_bucket(Bucket=settings.s3_bucket)


def _put_object_sync(key: str, body: bytes, content_type: str) -> None:
    _client().put_object(
        Bucket=settings.s3_bucket, Key=key, Body=body, ContentType=content_type
    )


async def upload_thumbnail(body: bytes, content_type: str, link_id: str) -> str:
    ext = content_type.split("/")[-1].split("+")[0] or "jpg"
    key = f"thumbnails/{link_id}/{uuid4().hex}.{ext}"
    await asyncio.to_thread(_put_object_sync, key, body, content_type)
    return key


def is_configured() -> bool:
    return bool(settings.s3_endpoint_url)


def public_url(key: str | None) -> str | None:
    if not key or not is_configured():
        return None
    if settings.s3_public_base_url:
        return f"{settings.s3_public_base_url.rstrip('/')}/{key}"
    base = settings.s3_endpoint_url.rstrip("/")
    return f"{base}/{settings.s3_bucket}/{key}"
