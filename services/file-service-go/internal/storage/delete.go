package storage

import (
    "context"

    "github.com/minio/minio-go/v7"
)

func (m *MinioClient) DeleteObject(ctx context.Context, objectKey string) error {
    return m.client.RemoveObject(ctx, m.bucket, objectKey, minio.RemoveObjectOptions{})
}