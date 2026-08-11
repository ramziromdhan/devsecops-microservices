package handler

import (
    "database/sql"
    "fmt"
    "log" // <--- AJOUT IMPORTANT POUR LES LOGS
    "net/http"
    "time"

    "github.com/gin-gonic/gin"
    "github.com/google/uuid"
    _ "github.com/lib/pq"
    "github.com/ramziromdhan/devsecops-microservices/file-service/config"
    "github.com/ramziromdhan/devsecops-microservices/file-service/internal/storage"
)

type Handler struct {
    cfg   *config.Config
    minio *storage.MinioClient
    db    *sql.DB
}

func New(cfg *config.Config, minio *storage.MinioClient) *Handler {
    // Ne pas ignorer l'erreur sql.Open au cas où l'URL est mal formatée
    db, err := sql.Open("postgres", cfg.DatabaseURL)
    if err != nil {
        log.Fatalf("Failed to open DB connection: %v", err)
    }
    return &Handler{cfg: cfg, minio: minio, db: db}
}

type InitiateRequest struct {
    OriginalName string `json:"original_name" binding:"required"`
    SizeBytes    int64  `json:"size_bytes" binding:"required"`
    MimeType     string `json:"mime_type" binding:"required"`
    SHA256Hash   string `json:"sha256_hash" binding:"required"`
}

func (h *Handler) InitiateUpload(c *gin.Context) {
    ownerEmail := c.GetString("email")

    var req InitiateRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }

    allowed := map[string]bool{
        "application/pdf": true,
        "image/png":       true,
        "image/jpeg":      true,
        "text/plain":      true,
        "text/csv":        true,
    }
    if !allowed[req.MimeType] {
        c.JSON(http.StatusBadRequest, gin.H{"error": "MIME type not allowed"})
        return
    }

    if req.SizeBytes > 500*1024*1024 {
        c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "File too large (max 500MB)"})
        return
    }

    fileID := uuid.New().String()
    storageKey := fmt.Sprintf("%s/%s", ownerEmail, fileID)

    // CORRECTION ICI : Appel de la bonne méthode avec le 4ème paramètre vide ("")
    presignedURL, err := h.minio.PresignedPutURLPublic(c.Request.Context(), storageKey, 1*time.Hour, "")
    if err != nil {
        // AFFICHAGE DE L'ERREUR DANS LES LOGS KUBERNETES
        log.Printf("[ERROR] Failed to generate MinIO presigned URL: %v", err)
        c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate upload URL"})
        return
    }

    _, err = h.db.ExecContext(c.Request.Context(), `
        INSERT INTO files (id, owner_email, original_name, storage_key, size_bytes, mime_type, sha256_hash, status)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending')`,
        fileID, ownerEmail, req.OriginalName, storageKey,
        req.SizeBytes, req.MimeType, req.SHA256Hash,
    )
    if err != nil {
        // AFFICHAGE DE L'ERREUR DANS LES LOGS KUBERNETES
        log.Printf("[ERROR] Failed to insert into Postgres: %v", err)
        c.JSON(http.StatusInternalServerError, gin.H{"error": "Database error"})
        return
    }

    c.JSON(http.StatusCreated, gin.H{
        "file_id":      fileID,
        "presigned_url": presignedURL,
        "expires_in":   "3600s",
        "storage_key":  storageKey,
    })
}

func (h *Handler) CompleteUpload(c *gin.Context) {
    fileID := c.Param("id")
    ownerEmail := c.GetString("email")

    var storageKey, declaredHash string
    err := h.db.QueryRowContext(c.Request.Context(), `
        SELECT storage_key, sha256_hash FROM files
        WHERE id=$1 AND owner_email=$2 AND status='pending'`,
        fileID, ownerEmail,
    ).Scan(&storageKey, &declaredHash)
    if err != nil {
        log.Printf("[ERROR] DB File lookup failed for %s: %v", fileID, err)
        c.JSON(http.StatusNotFound, gin.H{"error": "File not found or already completed"})
        return
    }

    computedHash, err := h.minio.ComputeSHA256(c.Request.Context(), storageKey)
    if err != nil {
        log.Printf("[ERROR] MinIO SHA256 computation failed: %v", err)
        c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to compute hash"})
        return
    }

    if computedHash != declaredHash {
        // Note: Assure-toi que la méthode DeleteObject existe bien dans ton storage.go !
        // Si elle n'existe pas, cela créera une erreur de compilation ici.
        h.minio.DeleteObject(c.Request.Context(), storageKey) 
        h.db.ExecContext(c.Request.Context(),
            "UPDATE files SET status='corrupted' WHERE id=$1", fileID)
        c.JSON(http.StatusUnprocessableEntity, gin.H{
            "error":         "Integrity check failed",
            "declared_hash": declaredHash,
            "computed_hash": computedHash,
        })
        return
    }

    h.db.ExecContext(c.Request.Context(),
        "UPDATE files SET status='ready', uploaded_at=NOW() WHERE id=$1", fileID)

    c.JSON(http.StatusOK, gin.H{
        "file_id": fileID,
        "status":  "ready",
        "sha256":  computedHash,
    })
}

func (h *Handler) UploadDirect(c *gin.Context) {
    c.JSON(http.StatusOK, gin.H{
        "status":  "ok",
        "service": "file-service-go",
        "message": "Use POST /files/initiate for presigned upload",
    })
}

func (h *Handler) PresignPart(c *gin.Context) {
    fileID := c.Param("id")
    ownerEmail := c.GetString("email")

    var body struct {
        PartNumber int `json:"part_number" binding:"required"`
    }
    if err := c.ShouldBindJSON(&body); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }

    var storageKey string
    err := h.db.QueryRowContext(c.Request.Context(), `
        SELECT storage_key FROM files
        WHERE id=$1 AND owner_email=$2 AND status='pending'`,
        fileID, ownerEmail,
    ).Scan(&storageKey)
    if err != nil {
        c.JSON(http.StatusNotFound, gin.H{"error": "File not found"})
        return
    }

    partKey := fmt.Sprintf("%s/part-%d", storageKey, body.PartNumber)

    // CORRECTION ICI AUSSI
    presignedURL, err := h.minio.PresignedPutURLPublic(c.Request.Context(), partKey, 15*time.Minute, "")
    if err != nil {
        log.Printf("[ERROR] MinIO PresignPart failed: %v", err)
        c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate part URL"})
        return
    }

    c.JSON(http.StatusOK, gin.H{
        "part_number":  body.PartNumber,
        "presigned_url": presignedURL,
        "expires_in":   "900s",
    })
}