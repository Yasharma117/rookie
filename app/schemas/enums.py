from enum import StrEnum


class LinkStatus(StrEnum):
    pending = "pending"
    enriched = "enriched"
    failed = "failed"


class SourcePlatform(StrEnum):
    instagram = "instagram"
    linkedin = "linkedin"
    youtube = "youtube"
    x = "x"
    tiktok = "tiktok"
    vimeo = "vimeo"
    reddit = "reddit"
    web = "web"


class AssignedBy(StrEnum):
    user = "user"
    model = "model"
    rule = "rule"


class IngestChannel(StrEnum):
    share_sheet = "share_sheet"
    telegram = "telegram"
    whatsapp = "whatsapp"
    email = "email"
    web = "web"
