package config

import (
    "os"
    "strings"
)

type Config struct {
    Port               string
    JWTSecret          string
    MinioEndpoint      string
    MinioPublicEndpoint string  // ← ajouter
    MinioAccessKey     string
    MinioSecretKey     string
    MinioBucket        string
    MinioUseSSL        bool
    DatabaseURL        string
}

func Load() *Config {
    dbURL := getEnv("DATABASE_URL", "")
    // Forcer sslmode=disable si pas déjà présent
    if dbURL != "" && !strings.Contains(dbURL, "sslmode") {
        if strings.Contains(dbURL, "?") {
            dbURL += "&sslmode=disable"
        } else {
            dbURL += "?sslmode=disable"
        }
    }

    return &Config{
        Port:                getEnv("PORT", "8003"),
        JWTSecret:           getEnv("JWT_SECRET_KEY", ""),
        MinioEndpoint:       getEnv("MINIO_ENDPOINT", "minio:9000"),
        MinioPublicEndpoint: getEnv("MINIO_PUBLIC_ENDPOINT", ""),
        MinioAccessKey:      getEnv("MINIO_ACCESS_KEY", ""),
        MinioSecretKey:      getEnv("MINIO_SECRET_KEY", ""),
        MinioBucket:         getEnv("MINIO_BUCKET", "uploads"),
        MinioUseSSL:         getEnv("MINIO_USE_SSL", "false") == "true",
        DatabaseURL:         dbURL,
    }
}

func getEnv(key, defaultVal string) string {
    if val := os.Getenv(key); val != "" {
        return val
    }
    return defaultVal
}