package middleware

import (
    "net/http"
    "strings"

    "github.com/gin-gonic/gin"
    "github.com/golang-jwt/jwt/v5"
)

func JWTAuth(secret string) gin.HandlerFunc {
    return func(c *gin.Context) {
        authHeader := c.GetHeader("Authorization")
        if authHeader == "" || !strings.HasPrefix(authHeader, "Bearer ") {
            c.AbortWithStatusJSON(http.StatusUnauthorized,
                gin.H{"error": "Authorization header required"})
            return
        }

        tokenStr := strings.TrimPrefix(authHeader, "Bearer ")

        token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
            if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
                return nil, jwt.ErrSignatureInvalid
            }
            return []byte(secret), nil
        })

        if err != nil || !token.Valid {
            c.AbortWithStatusJSON(http.StatusUnauthorized,
                gin.H{"error": "Invalid or expired token"})
            return
        }

        claims, ok := token.Claims.(jwt.MapClaims)
        if !ok {
            c.AbortWithStatusJSON(http.StatusUnauthorized,
                gin.H{"error": "Invalid token claims"})
            return
        }

        email, ok := claims["sub"].(string)
        if !ok || email == "" {
            c.AbortWithStatusJSON(http.StatusUnauthorized,
                gin.H{"error": "Invalid token subject"})
            return
        }

        c.Set("email", email)
        c.Next()
    }
}