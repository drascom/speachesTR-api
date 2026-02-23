# Coolify Deployment (CPU, STT, TR+EN Policy)

This document defines the production deployment profile used by this repository.

## Target profile

- Runtime: CPU
- Deploy mode: Dockerfile build from Git repository
- Auth: API key required
- UI: disabled
- Model preload: `Systran/faster-whisper-medium`
- Language policy: clients must send only `tr` or `en` per request

## 1. Git and branches

This repository tracks upstream `speaches-ai/speaches` and uses `main` as default branch.

Recommended sync flow:

```bash
git fetch upstream
git checkout main
git merge upstream/master
git push origin main
```

## 2. Coolify application setup

Create an **Application** in Coolify with:

- Source: `https://github.com/drascom/speachesTR-api`
- Branch: `main`
- Build type: Dockerfile
- Dockerfile path: `/Dockerfile`
- Internal port: `8000`
- Health check path: `/health`

## 3. Persistent volume

Mount a persistent volume to:

- `/home/ubuntu/.cache/huggingface/hub`

This keeps downloaded model files between restarts and deployments.

## 4. Environment variables

Use `.env.production.example` as baseline. Required values:

- `API_KEY`
- `ENABLE_UI=false`
- `PRELOAD_MODELS=["Systran/faster-whisper-medium"]`

Optional:

- `ALLOW_ORIGINS=["https://your-frontend.example.com"]`

## 5. TR+EN request policy

Speaches does not expose a native environment variable to hard-limit accepted languages.  
Policy is enforced by client contract (or optional API gateway rules):

- Clients must send `language=tr` or `language=en`.
- Do not send other language values in production traffic.

## 6. Validation checklist

1. `GET /health` returns `200`.
2. Request without `Authorization: Bearer <API_KEY>` returns `401/403`.
3. STT request with `language=tr` succeeds.
4. STT request with `language=en` succeeds.
5. After redeploy, the model is reused from volume cache.

