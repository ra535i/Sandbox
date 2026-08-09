# setup-cluster.ps1
# Run this script after a cluster reset to restore all cluster infrastructure.
# Must be run as Administrator (required for hosts file update).

Write-Host "Setting up cluster infrastructure..." -ForegroundColor Cyan

# ── 1. MetalLB (LoadBalancer support) ────────────────────────────────────────
Write-Host "`n[1/6] Installing MetalLB..." -ForegroundColor Yellow
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

# ── 6. Update hosts file ──────────────────────────────────────────────────────
Write-Host "`n[6/6] Updating hosts file..." -ForegroundColor Yellow

# Wait for ingress controller to get an IP from MetalLB
Start-Sleep -Seconds 5
$ingressIP = kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath="{.status.loadBalancer.ingress[0].ip}"

if ($ingressIP) {
    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $hostnames = @("dev.sethsandbox.com", "qa.sethsandbox.com", "uat.sethsandbox.com", "stage.sethsandbox.com", "sethsandbox.com", "argocd-local.com")
    $hostsContent = Get-Content $hostsFile

    # Remove existing sandbox/argocd entries
    $hostsContent = $hostsContent | Where-Object { $_ -notmatch "sethsandbox\.com|argocd-local\.com" }

    # Add new entries
    $hostsContent += ""
    $hostnames | ForEach-Object { $hostsContent += "$ingressIP  $_" }

    Set-Content $hostsFile $hostsContent
    Write-Host "Hosts file updated with IP: $ingressIP" -ForegroundColor Green
} else {
    Write-Host "Could not detect ingress IP. Update hosts file manually." -ForegroundColor Red
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n✓ Cluster setup complete!" -ForegroundColor Green
Write-Host "`nArgoCD URL:  http://argocd-local.com" -ForegroundColor Cyan
Write-Host "Username:    admin" -ForegroundColor Cyan

$encoded = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
Write-Host "Password:    $password" -ForegroundColor Cyan

Write-Host "`nRemember to sync your ArgoCD applications after setup." -ForegroundColor Yellow
