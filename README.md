# Sandbox

A self-contained static website for sandbox testing — no frameworks, no build tools, no external dependencies. Everything works offline.

## Running locally

### Option 1 — VS Code Live Server (recommended)

1. Open the repository folder in VS Code.
2. Install the **Live Server** extension (ritwickdey.LiveServer) if you haven't already.
3. Right-click `index.html` in the Explorer panel and choose **"Open with Live Server"**.
4. Your browser will open automatically and hot-reload on every save.

### Option 2 — Python built-in HTTP server

```bash
# Python 3
python3 -m http.server 8080
# then open http://localhost:8080
```

### Option 3 — Docker

```powershell
docker build -t sandbox-app:latest .
docker run -d -p 8080:80 --name sandbox-test sandbox-app:latest
# open http://localhost:8080
docker stop sandbox-test && docker rm sandbox-test
```

---

## Kubernetes Deployment (Docker Desktop)

The application is deployed to a local Kubernetes cluster via **ArgoCD** and **Helm**, with environments for dev, qa, uat, stage, and production.

### Prerequisites

- Docker Desktop with Kubernetes enabled
- `kubectl` configured for the `docker-desktop` context
- Git repository connected to ArgoCD

### Environments

| Environment | URL | Replicas |
|---|---|---|
| Dev | http://dev.sethsandbox.com | 1 |
| QA | http://qa.sethsandbox.com | 1 |
| UAT | http://uat.sethsandbox.com | 1 |
| Stage | http://stage.sethsandbox.com | 1 |
| Production | http://sethsandbox.com | 2 |
| ArgoCD | http://argocd-local.com | — |

### Initial cluster setup

After a Kubernetes cluster reset, run the setup script as Administrator:

```powershell
.\setup-cluster.ps1
```

This script will:
1. Install the **Nginx Ingress Controller**
2. Install **ArgoCD** (ClusterIP, routed via ingress)
3. Start a **local Docker registry** at `localhost:5000` and push the app image
4. Update the Windows **hosts file** with all environment domains
5. Configure **netsh portproxy** to forward Windows ports 80/443 to the cluster ingress NodePorts

> The script self-elevates to Administrator via UAC if not already elevated.

### Deploying via ArgoCD

1. Access ArgoCD at **http://argocd-local.com** (username: `admin`, password printed by setup script)
2. Create an Application pointing to this repository
   - **Path:** `helm/sandbox-app`
   - **Values file:** `values-dev.yaml` (or qa/uat/stage/prod)
3. Click **Sync**

### Building and pushing the Docker image

The cluster uses a local registry (`localhost:5000`). After code changes:

```powershell
docker build -t sandbox-app:latest .
docker tag sandbox-app:latest localhost:5000/sandbox-app:latest
docker push localhost:5000/sandbox-app:latest
```

Then trigger a sync in ArgoCD.

### Project structure

```
Sandbox/
├── Dockerfile                        # Ubuntu + nginx image
├── index.html                        # Application
├── setup-cluster.ps1                 # One-command cluster setup
└── helm/
    └── sandbox-app/
        ├── Chart.yaml
        ├── values.yaml               # Defaults
        ├── values-dev.yaml
        ├── values-qa.yaml
        ├── values-uat.yaml
        ├── values-stage.yaml
        ├── values-prod.yaml
        └── templates/
            ├── deployment.yaml
            ├── service.yaml
            └── ingress.yaml
```

---

## What's inside

| File | Purpose |
|------|---------|
| `index.html` | Single-file app — all HTML, CSS, and JS in one place |
| `Dockerfile` | Builds a production nginx image on Ubuntu |
| `setup-cluster.ps1` | Bootstraps the full local Kubernetes infrastructure |
| `helm/` | Helm chart for multi-environment Kubernetes deployment |
| `README.md` | This file |

## Features

- **Hero section** with a live clock that ticks every second.
- **Interactive Form Tester** covering every common input type:
  text, email, number, password (with show/hide toggle), date picker, dropdown, radio buttons, checkboxes, textarea, range slider with live value, and file upload.
- **Client-side validation** with inline error messages — no server required.
- **Success summary** that prints all submitted values in a green panel.
- **"Fill with random data"** button for quick testing.
- **"Clear form"** button.
- **Submission counter** stored in `localStorage` so it persists across page reloads.
- CSS fade-in animation on page load.
- Responsive layout that works on mobile and desktop.