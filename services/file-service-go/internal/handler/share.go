package handler

import (
    "crypto/rand"
    "encoding/hex"
    "net/http"
    "time"

    "github.com/gin-gonic/gin"
)

type ShareRequest struct {
    FileID         string `json:"file_id" binding:"required"`
    RecipientEmail string `json:"recipient_email" binding:"required,email"`
    ExpiresInHours int    `json:"expires_in_hours"`
    MaxDownloads   int    `json:"max_downloads"`
}

func (h *Handler) CreateShareLink(c *gin.Context) {
    ownerEmail := c.GetString("email")

    var req ShareRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }

    // Valeurs par défaut
    if req.ExpiresInHours == 0 {
        req.ExpiresInHours = 24
    }
    if req.MaxDownloads == 0 {
        req.MaxDownloads = 5
    }

    // Vérifier que le fichier appartient à l'utilisateur
    var storageKey string
    err := h.db.QueryRowContext(c.Request.Context(), `
        SELECT storage_key FROM files
        WHERE id=$1 AND owner_email=$2 AND status='ready'`,
        req.FileID, ownerEmail,
    ).Scan(&storageKey)
    if err != nil {
        c.JSON(http.StatusNotFound, gin.H{"error": "File not found or not ready"})
        return
    }

    // Générer un token cryptographiquement sûr
    tokenBytes := make([]byte, 32)
    if _, err := rand.Read(tokenBytes); err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": "Token generation failed"})
        return
    }
    token := hex.EncodeToString(tokenBytes)

    expiresAt := time.Now().Add(time.Duration(req.ExpiresInHours) * time.Hour)

    // Insérer en base
    var shareID string
    err = h.db.QueryRowContext(c.Request.Context(), `
        INSERT INTO share_links
            (file_id, created_by, token, recipient_email, max_downloads, expires_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id`,
        req.FileID, ownerEmail, token,
        req.RecipientEmail, req.MaxDownloads, expiresAt,
    ).Scan(&shareID)
    if err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": "Database error"})
        return
    }

    c.JSON(http.StatusCreated, gin.H{
        "share_id":        shareID,
        "token":           token,
        "recipient_email": req.RecipientEmail,
        "expires_at":      expiresAt,
        "max_downloads":   req.MaxDownloads,
    })
}