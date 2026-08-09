# setup-cluster.ps1
# Run this script after a cluster reset to restore all cluster infrastructure.
# Must be run as Administrator (required for hosts file update).

Write-Host "Setting up cluster infrastructure..." -ForegroundColor Cyan

# ── 1. Nginx Ingress Controller ───────────────────────────────────────────────
Write-Host "`n[1/4] Installing Nginx Ingress Controller..." -ForegroundColor Yellow
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s

# ── 2. ArgoCD ─────────────────────────────────────────────────────────────────
Write-Host "`n[2/4] Installing ArgoCD..." -ForegroundColor Yellow
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# Keep ArgoCD as ClusterIP — all traffic routes through nginx ingress by hostname
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Create ArgoCD ingress
@"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - host: argocd-local.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
"@ | kubectl apply -f -

# ── 3. Local Docker Registry ──────────────────────────────────────────────────
Write-Host "`n[3/4] Starting local Docker registry..." -ForegroundColor Yellow
$registryRunning = docker ps --filter name=local-registry --filter status=running -q
if ($registryRunning) {
    Write-Host "Local registry already running." -ForegroundColor Green
} else {
    docker run -d -p 5000:5000 --restart=always --name local-registry registry:2
}

Write-Host "Building and pushing sandbox-app image..." -ForegroundColor Yellow
docker build -t sandbox-app:latest .
docker tag sandbox-app:latest localhost:5000/sandbox-app:latest
docker push localhost:5000/sandbox-app:latest

# ── 4. Update hosts file ──────────────────────────────────────────────────────
# Docker Desktop routes LoadBalancer services on port 80 via localhost natively.
# All hostnames resolve to 127.0.0.1.
Write-Host "`n[4/4] Updating hosts file..." -ForegroundColor Yellow
$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$hostnames = @("dev.sethsandbox.com", "qa.sethsandbox.com", "uat.sethsandbox.com", "stage.sethsandbox.com", "sethsandbox.com", "argocd-local.com")
$hostsContent = Get-Content $hostsFile

$hostsContent = $hostsContent | Where-Object { $_ -notmatch "sethsandbox\.com|argocd-local\.com" }
$hostsContent += ""
$hostnames | ForEach-Object { $hostsContent += "127.0.0.1  $_" }
Set-Content $hostsFile $hostsContent
Write-Host "Hosts file updated." -ForegroundColor Green

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n✓ Cluster setup complete!" -ForegroundColor Green
Write-Host "`nArgoCD URL:  http://argocd-local.com" -ForegroundColor Cyan
Write-Host "Username:    admin" -ForegroundColor Cyan

$encoded = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
Write-Host "Password:    $password" -ForegroundColor Cyan

Write-Host "`nRemember to sync your ArgoCD applications after setup." -ForegroundColor Yellow
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=120s

@"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.17.255.200-172.17.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-advertisement
  namespace: metallb-system
"@ | kubectl apply -f -

# ── 2. Nginx Ingress Controller ───────────────────────────────────────────────
Write-Host "`n[2/6] Installing Nginx Ingress Controller..." -ForegroundColor Yellow
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s

# ── 3. ArgoCD ─────────────────────────────────────────────────────────────────
Write-Host "`n[3/6] Installing ArgoCD..." -ForegroundColor Yellow
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd --type=merge -p '{\"spec\": {\"type\": \"LoadBalancer\"}}'

# ── 4. Wait for ArgoCD to be ready ────────────────────────────────────────────
Write-Host "`n[4/6] Waiting for ArgoCD pods to be ready (this may take a few minutes)..." -ForegroundColor Yellow
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Create ArgoCD ingress
@"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
spec:
  ingressClassName: nginx
  rules:
  - host: argocd-local.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
"@ | kubectl apply -f -

# ── 5. Local Docker Registry ──────────────────────────────────────────────────
Write-Host "`n[5/6] Starting local Docker registry..." -ForegroundColor Yellow
$registryRunning = docker ps --filter name=local-registry --filter status=running -q
if ($registryRunning) {
    Write-Host "Local registry already running." -ForegroundColor Green
} else {
    docker run -d -p 5000:5000 --restart=always --name local-registry registry:2
}

Write-Host "`nBuilding and pushing sandbox-app image..." -ForegroundColor Yellow
docker build -t sandbox-app:latest .
docker tag sandbox-app:latest localhost:5000/sandbox-app:latest
docker push localhost:5000/sandbox-app:latest

# ── 6. Nginx Proxy Container (Windows → K8s ingress) ─────────────────────────
Write-Host "`n[6/6] Configuring nginx proxy container..." -ForegroundColor Yellow

# Get current NodePort for the ingress controller HTTP port
$httpNodePort = kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath="{.spec.ports[?(@.name=='http')].nodePort}"
Write-Host "Ingress NodePort: $httpNodePort" -ForegroundColor Cyan

# Write nginx config to temp file
$nginxConf = @"
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://host.docker.internal:$httpNodePort;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
    }
}
"@

$nginxConfPath = "$env:TEMP\nginx-proxy.conf"
$nginxConf | Set-Content $nginxConfPath -Encoding UTF8

# Remove existing proxy container if present
$existing = docker ps -a --filter name=nginx-proxy -q
if ($existing) {
    Write-Host "Removing existing nginx-proxy container..." -ForegroundColor Yellow
    docker rm -f nginx-proxy | Out-Null
}

# Start nginx proxy container
docker run -d `
    --name nginx-proxy `
    --restart=always `
    -p 80:80 `
    -v "${nginxConfPath}:/etc/nginx/conf.d/default.conf" `
    nginx:alpine

Write-Host "nginx proxy container started on port 80 → NodePort $httpNodePort" -ForegroundColor Green

# ── Update hosts file ─────────────────────────────────────────────────────────
    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $hostnames = @("dev.sethsandbox.com", "qa.sethsandbox.com", "uat.sethsandbox.com", "stage.sethsandbox.com", "sethsandbox.com", "argocd-local.com")
    $hostsContent = Get-Content $hostsFile

    # Remove existing sandbox/argocd entries
    $hostsContent = $hostsContent | Where-Object { $_ -notmatch "sethsandbox\\.com|argocd-local\\.com" }

    # Add new entries pointing to localhost (port-forwarded ingress)
    $hostsContent += ""
    $hostnames | ForEach-Object { $hostsContent += "127.0.0.1  $_" }

    Set-Content $hostsFile $hostsContent
    Write-Host "Hosts file updated to 127.0.0.1" -ForegroundColor Green

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n✓ Cluster setup complete!" -ForegroundColor Green
Write-Host "`nArgoCD URL:  http://argocd-local.com" -ForegroundColor Cyan
Write-Host "Username:    admin" -ForegroundColor Cyan

$encoded = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
Write-Host "Password:    $password" -ForegroundColor Cyan

Write-Host "`nRemember to sync your ArgoCD applications after setup." -ForegroundColor Yellow
