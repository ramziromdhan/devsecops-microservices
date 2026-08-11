-- Tables pour le système de transfert de fichiers

CREATE TABLE IF NOT EXISTS files (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_email   VARCHAR(255) NOT NULL,
    original_name VARCHAR(500) NOT NULL,
    storage_key   VARCHAR(500) UNIQUE NOT NULL,
    size_bytes    BIGINT NOT NULL,
    mime_type     VARCHAR(100) NOT NULL,
    sha256_hash   VARCHAR(64) NOT NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','ready','corrupted','expired')),
    uploaded_at   TIMESTAMP,
    expires_at    TIMESTAMP,
    created_at    TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS share_links (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id          UUID NOT NULL REFERENCES files(id),
    created_by       VARCHAR(255) NOT NULL,
    token            VARCHAR(64) UNIQUE NOT NULL,
    recipient_email  VARCHAR(255),
    max_downloads    INTEGER DEFAULT 5,
    download_count   INTEGER DEFAULT 0,
    expires_at       TIMESTAMP NOT NULL,
    is_revoked       BOOLEAN DEFAULT false,
    created_at       TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS download_logs (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    share_link_id      UUID NOT NULL REFERENCES share_links(id),
    ip_address         VARCHAR(45),
    user_agent         TEXT,
    integrity_verified BOOLEAN DEFAULT false,
    downloaded_at      TIMESTAMP DEFAULT NOW()
);

-- Index pour les performances
CREATE INDEX IF NOT EXISTS idx_files_owner ON files(owner_email);
CREATE INDEX IF NOT EXISTS idx_share_links_token ON share_links(token);
CREATE INDEX IF NOT EXISTS idx_share_links_expires ON share_links(expires_at);
