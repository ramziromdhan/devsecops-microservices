package handler

import (
    "net/http"
    "time"

    "github.com/gin-gonic/gin"
)

func (h *Handler) DownloadFile(c *gin.Context) {
    token := c.Param("token")

    // Valider le share link
    var fileID, storageKey, sha256Hash string
    var downloadCount, maxDownloads int
    err := h.db.QueryRowContext(c.Request.Context(), `
        SELECT f.id, f.storage_key, f.sha256_hash,
               sl.download_count, sl.max_downloads
        FROM share_links sl
        JOIN files f ON f.id = sl.file_id
        WHERE sl.token = $1
          AND sl.expires_at > NOW()
          AND sl.is_revoked = false
          AND f.status = 'ready'`,
        token,
    ).Scan(&fileID, &storageKey, &sha256Hash, &downloadCount, &maxDownloads)

    if err != nil {
        c.JSON(http.StatusNotFound, gin.H{"error": "Invalid or expired link"})
        return
    }

    if downloadCount >= maxDownloads {
        c.JSON(http.StatusForbidden, gin.H{"error": "Download limit reached"})
        return
    }

    // Générer l'URL pré-signée de téléchargement (TTL 5 min)
    downloadURL, err := h.minio.PresignedGetURL(
        c.Request.Context(), storageKey, 5*time.Minute)
    if err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate download URL"})
        return
    }

    // Incrémenter le compteur et logger
    h.db.ExecContext(c.Request.Context(), `
        UPDATE share_links
        SET download_count = download_count + 1
        WHERE token = $1`, token)

    h.db.ExecContext(c.Request.Context(), `
        INSERT INTO download_logs
            (share_link_id, ip_address, user_agent, integrity_verified)
        SELECT id, $2, $3, false FROM share_links WHERE token = $1`,
        token,
        c.ClientIP(),
        c.GetHeader("User-Agent"),
    )

    c.JSON(http.StatusOK, gin.H{
        "download_url": downloadURL,
        "sha256_hash":  sha256Hash,
        "expires_in":   "300s",
        "message":      "Verify SHA256 after download and call PATCH /download/:token/verify",
    })
}

func (h *Handler) VerifyIntegrity(c *gin.Context) {
    token := c.Param("token")

    var body struct {
        IntegrityVerified bool `json:"integrity_verified"`
    }
    c.ShouldBindJSON(&body)

    h.db.ExecContext(c.Request.Context(), `
        UPDATE download_logs dl
        SET integrity_verified = $2
        FROM share_links sl
        WHERE sl.token = $1
          AND dl.share_link_id = sl.id
          AND dl.integrity_verified = false
        ORDER BY dl.downloaded_at DESC
        LIMIT 1`,
        token, body.IntegrityVerified,
    )

    c.JSON(http.StatusOK, gin.H{
        "verified": body.IntegrityVerified,
        "message":  "Integrity verification recorded",
    })
}