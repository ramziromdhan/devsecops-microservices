package main

import (
    "log"

    "github.com/gin-gonic/gin"
    "github.com/ramziromdhan/devsecops-microservices/file-service/config"
    "github.com/ramziromdhan/devsecops-microservices/file-service/internal/handler"
    "github.com/ramziromdhan/devsecops-microservices/file-service/internal/middleware"
    "github.com/ramziromdhan/devsecops-microservices/file-service/internal/storage"

    "github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
    cfg := config.Load()

    minioClient, err := storage.NewMinioClient(cfg)
    if err != nil {
        log.Fatalf("Failed to connect to MinIO: %v", err)
    }

    r := gin.Default()

    // Security headers middleware
    r.Use(func(c *gin.Context) {
        c.Header("X-Content-Type-Options", "nosniff")
        c.Header("X-Frame-Options", "DENY")
        c.Header("X-XSS-Protection", "1; mode=block")
        c.Header("Referrer-Policy", "strict-origin-when-cross-origin")
        c.Next()
    })

    h := handler.New(cfg, minioClient)

    // Health check
    r.GET("/health", func(c *gin.Context) {
        c.JSON(200, gin.H{"status": "ok", "service": "file-service-go"})
    })

    // Routes protégées par JWT
    auth := r.Group("/", middleware.JWTAuth(cfg.JWTSecret))
    {
        auth.POST("/files/initiate",         h.InitiateUpload)
        auth.POST("/files/:id/presign-part", h.PresignPart)
        auth.POST("/files/:id/complete",     h.CompleteUpload)
        auth.POST("/share",                  h.CreateShareLink)
        auth.GET("/download/:token",         h.DownloadFile)
        auth.PATCH("/download/:token/verify", h.VerifyIntegrity)
        auth.GET("/upload",                  h.UploadDirect)
        auth.POST("/upload",                 h.UploadDirect)
    }

    port := cfg.Port
    if port == "" {
        port = "8003"
    }

    log.Printf("File Service Go starting on :%s", port)
	r.GET("/metrics", gin.WrapH(promhttp.Handler()))
    if err := r.Run(":" + port); err != nil {
        log.Fatal(err)
    }
}