package storage

import (
    "context"
    "crypto/sha256"
    "fmt"
    "io"
    "strings" // <--- AJOUTE CECI
    "time"

    "github.com/minio/minio-go/v7"
    "github.com/minio/minio-go/v7/pkg/credentials"
    "github.com/ramziromdhan/devsecops-microservices/file-service/config"
)

type MinioClient struct {
    client *minio.Client
    bucket string
}

func NewMinioClient(cfg *config.Config) (*MinioClient, error) {
    client, err := minio.New(cfg.MinioEndpoint, &minio.Options{
        Creds:  credentials.NewStaticV4(cfg.MinioAccessKey, cfg.MinioSecretKey, ""),
        Secure: cfg.MinioUseSSL,
    })
    if err != nil {
        return nil, fmt.Errorf("minio init: %w", err)
    }

    // Créer le bucket s'il n'existe pas
    ctx := context.Background()
    exists, err := client.BucketExists(ctx, cfg.MinioBucket)
    if err != nil {
        return nil, fmt.Errorf("bucket check: %w", err)
    }
    if !exists {
        if err := client.MakeBucket(ctx, cfg.MinioBucket, minio.MakeBucketOptions{}); err != nil {
            return nil, fmt.Errorf("bucket create: %w", err)
        }
    }

    return &MinioClient{client: client, bucket: cfg.MinioBucket}, nil
}

// PresignedPutURL génère une URL pré-signée pour upload direct
func (m *MinioClient) PresignedPutURLPublic(
    ctx context.Context,
    objectKey string,
    ttl time.Duration,
    publicEndpoint string,
) (string, error) {
    // Générer avec l'endpoint interne
    u, err := m.client.PresignedPutObject(ctx, m.bucket, objectKey, ttl)
    if err != nil {
        return "", fmt.Errorf("presign put: %w", err)
    }

    // Remplacer l'endpoint interne par l'endpoint public
    if publicEndpoint != "" {
        internalHost := m.client.EndpointURL().Host
        return strings.Replace(u.String(), internalHost, publicEndpoint, 1), nil
    }
    return u.String(), nil
}

// PresignedGetURL génère une URL pré-signée pour download
func (m *MinioClient) PresignedGetURL(ctx context.Context, objectKey string, ttl time.Duration) (string, error) {
    url, err := m.client.PresignedGetObject(ctx, m.bucket, objectKey, ttl, nil)
    if err != nil {
        return "", fmt.Errorf("presign get: %w", err)
    }
    return url.String(), nil
}

// ComputeSHA256 calcule le hash SHA256 d'un objet déjà stocké dans MinIO
func (m *MinioClient) ComputeSHA256(ctx context.Context, objectKey string) (string, error) {
    obj, err := m.client.GetObject(ctx, m.bucket, objectKey, minio.GetObjectOptions{})
    if err != nil {
        return "", fmt.Errorf("get object: %w", err)
    }
    defer obj.Close()

    h := sha256.New()
    if _, err := io.Copy(h, obj); err != nil {
        return "", fmt.Errorf("hash compute: %w", err)
    }
    return fmt.Sprintf("%x", h.Sum(nil)), nil
}