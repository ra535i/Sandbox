# setup-cluster.ps1
# Run this script after a cluster reset to restore all cluster infrastructure.

# Self-elevate to Administrator if not already running as admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "Setting up cluster infrastructure..." -ForegroundColor Cyan

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

# -- 4. Update hosts file ----------------------------------------------------
# Docker Desktop routes LoadBalancer services on port 80 via localhost natively.
# All hostnames resolve to 127.0.0.1.
Write-Host "`n[4/5] Updating hosts file and registering port-forward task..." -ForegroundColor Yellow
$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$hostnames = @("dev.sethsandbox.com", "qa.sethsandbox.com", "uat.sethsandbox.com", "stage.sethsandbox.com", "sethsandbox.com", "argocd-local.com")
$hostsContent = Get-Content $hostsFile

$hostsContent = $hostsContent | Where-Object { $_ -notmatch "sethsandbox\.com|argocd-local\.com" }
$hostsContent += ""
# Use the ingress controller's external IP assigned by Docker Desktop
$ingressIP = kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
if (-not $ingressIP) { $ingressIP = "127.0.0.1" }
Write-Host "Using ingress IP: $ingressIP" -ForegroundColor Cyan
$hostnames | ForEach-Object { $hostsContent += "$ingressIP  $_" }
Set-Content $hostsFile $hostsContent
Write-Host "Hosts file updated." -ForegroundColor Green

# -- 5. netsh portproxy (Windows port 80/443 -> K8s ingress NodePorts) --------
Write-Host "`n[5/5] Configuring port forwarding..." -ForegroundColor Yellow
$nodeIP    = kubectl get nodes -o jsonpath="{.items[0].status.addresses[?(@.type=='InternalIP')].address}"
$httpPort  = kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath="{.spec.ports[?(@.name=='http')].nodePort}"
$httpsPort = kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath="{.spec.ports[?(@.name=='https')].nodePort}"

# Remove existing rules before adding new ones
netsh interface portproxy delete v4tov4 listenport=80  listenaddress=0.0.0.0 2>$null
netsh interface portproxy delete v4tov4 listenport=443 listenaddress=0.0.0.0 2>$null
netsh interface portproxy add v4tov4 listenport=80  listenaddress=0.0.0.0 connectport=$httpPort  connectaddress=$nodeIP
netsh interface portproxy add v4tov4 listenport=443 listenaddress=0.0.0.0 connectport=$httpsPort connectaddress=$nodeIP
Write-Host "Port forwarding configured: 80 -> $nodeIP`:$httpPort, 443 -> $nodeIP`:$httpsPort" -ForegroundColor Green

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
