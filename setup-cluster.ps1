# setup-cluster.ps1
# Run this script after a cluster reset to restore all cluster infrastructure.

# Self-elevate to Administrator if not already running as admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "Setting up cluster infrastructure..." -ForegroundColor Cyan
$repoRoot = $PSScriptRoot
$reconcileScript = Join-Path $repoRoot "scripts\reconcile-ingress-routing.ps1"

# ── 1. Nginx Ingress Controller ───────────────────────────────────────────────
Write-Host "`n[1/4] Installing Nginx Ingress Controller..." -ForegroundColor Yellow
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s

# ── 2. ArgoCD ─────────────────────────────────────────────────────────────────
Write-Host "`n[2/4] Installing ArgoCD..." -ForegroundColor Yellow
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# Keep ArgoCD as ClusterIP - all traffic routes through nginx ingress by hostname
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

# -- 3. Local Docker Registry ------------------------------------------------
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

# -- 4. Reconcile hosts + portproxy ------------------------------------------
Write-Host "`n[4/5] Reconciling hosts and port forwarding..." -ForegroundColor Yellow
if (-not (Test-Path $reconcileScript)) {
  throw "Missing helper script: $reconcileScript"
}

powershell -ExecutionPolicy Bypass -File $reconcileScript

# -- 5. Register auto-heal task ----------------------------------------------
Write-Host "`n[5/5] Registering auto-heal scheduled task..." -ForegroundColor Yellow
$taskName = "Sandbox-Ingress-Reconcile"
$taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$reconcileScript`""
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$taskPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable

Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
Write-Host "Scheduled task '$taskName' registered for user logon." -ForegroundColor Green

# Run ArgoCD in insecure (HTTP) mode to prevent redirect loops
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{\"data\":{\"server.insecure\":\"true\"}}'
kubectl rollout restart deployment argocd-server -n argocd | Out-Null

# -- Summary -----------------------------------------------------------------
Write-Host "`nCluster setup complete!" -ForegroundColor Green
Write-Host "`nArgoCD URL:  http://argocd-local.com" -ForegroundColor Cyan
Write-Host "Username:    admin" -ForegroundColor Cyan

$encoded = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
Write-Host "Password:    $password" -ForegroundColor Cyan

Write-Host "`nRemember to sync your ArgoCD applications after setup." -ForegroundColor Yellow
