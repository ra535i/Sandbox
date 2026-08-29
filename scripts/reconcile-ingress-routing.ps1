# reconcile-ingress-routing.ps1
# Idempotently repairs host mappings and Windows portproxy routes for local ingress.

param(
    [string[]]$Hostnames = @(
        "dev.sethsandbox.com",
        "qa.sethsandbox.com",
        "uat.sethsandbox.com",
        "stage.sethsandbox.com",
        "sethsandbox.com",
        "argocd-local.com"
    ),
    [string]$HostsTargetIp = "127.0.0.1"
)

# Self-elevate because hosts and netsh require Administrator rights.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"

function Get-ClusterValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonPath,
        [Parameter(Mandatory = $true)]
        [string[]]$KubectlArgs
    )

    $value = & kubectl @KubectlArgs -o "jsonpath=$JsonPath"
    return $value.Trim()
}

function Ensure-PortForwardTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$KubectlCommand
    )

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -Command $KubectlCommand"
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    if ($existingTask) {
        Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
    } else {
        Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings | Out-Null
    }

    $running = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($running -and $running.State -eq "Running") {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }

    Start-ScheduledTask -TaskName $TaskName
}

function Test-HttpProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8
        return [PSCustomObject]@{
            Name = $Name
            Url = $Url
            Success = $true
            StatusCode = [int]$response.StatusCode
            Message = "OK"
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        return [PSCustomObject]@{
            Name = $Name
            Url = $Url
            Success = $false
            StatusCode = $statusCode
            Message = $_.Exception.Message
        }
    }
}

Write-Host "Reconciling local ingress networking..." -ForegroundColor Cyan

$nodeIP = Get-ClusterValue -KubectlArgs @("get", "nodes") -JsonPath "{.items[0].status.addresses[?(@.type=='InternalIP')].address}"
$httpPort = Get-ClusterValue -KubectlArgs @("get", "svc", "-n", "ingress-nginx", "ingress-nginx-controller") -JsonPath "{.spec.ports[?(@.name=='http')].nodePort}"
$httpsPort = Get-ClusterValue -KubectlArgs @("get", "svc", "-n", "ingress-nginx", "ingress-nginx-controller") -JsonPath "{.spec.ports[?(@.name=='https')].nodePort}"
$forwardTaskName = "Sandbox-Ingress-PortForward"

# Update hosts file entries for all sandbox hostnames.
$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsFile
$hostsContent = $hostsContent | Where-Object { $_ -notmatch "sethsandbox\.com|argocd-local\.com" }
$hostsContent += ""
$Hostnames | ForEach-Object { $hostsContent += "$HostsTargetIp  $_" }
Set-Content $hostsFile $hostsContent

# Refresh proxy rules, then choose the best forwarding strategy.
netsh interface portproxy delete v4tov4 listenport=80 listenaddress=0.0.0.0 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenport=443 listenaddress=0.0.0.0 2>$null | Out-Null

$nodeReachable = (Test-NetConnection -ComputerName $nodeIP -Port $httpPort -WarningAction SilentlyContinue).TcpTestSucceeded
if ($nodeReachable) {
    netsh interface portproxy add v4tov4 listenport=80 listenaddress=0.0.0.0 connectport=$httpPort connectaddress=$nodeIP | Out-Null
    netsh interface portproxy add v4tov4 listenport=443 listenaddress=0.0.0.0 connectport=$httpsPort connectaddress=$nodeIP | Out-Null

    if (Get-ScheduledTask -TaskName $forwardTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $forwardTaskName -ErrorAction SilentlyContinue
    }

    Write-Host "Forwarding mode: netsh portproxy" -ForegroundColor Green
    Write-Host "Portproxy 80 -> $nodeIP`:$httpPort" -ForegroundColor Green
    Write-Host "Portproxy 443 -> $nodeIP`:$httpsPort" -ForegroundColor Green
} else {
    $kubectlForward = 'kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 80:80 443:443 --address 127.0.0.1'
    Ensure-PortForwardTask -TaskName $forwardTaskName -KubectlCommand $kubectlForward

    Write-Host "Forwarding mode: kubectl port-forward fallback" -ForegroundColor Yellow
    Write-Host "Reason: node address $nodeIP`:$httpPort is not reachable from Windows." -ForegroundColor Yellow
    Write-Host "Scheduled task '$forwardTaskName' refreshed and started." -ForegroundColor Yellow
}

Write-Host "Hosts mapped to: $HostsTargetIp" -ForegroundColor Green

# Probe key entrypoints so failures are obvious immediately.
$probes = @(
    Test-HttpProbe -Name "ArgoCD" -Url "http://argocd-local.com",
    Test-HttpProbe -Name "Dev App" -Url "http://dev.sethsandbox.com"
)

Write-Host "`nEndpoint probe summary:" -ForegroundColor Cyan
$failed = $false
foreach ($probe in $probes) {
    if ($probe.Success) {
        Write-Host "[PASS] $($probe.Name): $($probe.Url) (HTTP $($probe.StatusCode))" -ForegroundColor Green
    } else {
        $failed = $true
        $codeText = if ($probe.StatusCode) { "HTTP $($probe.StatusCode)" } else { "no status code" }
        Write-Host "[FAIL] $($probe.Name): $($probe.Url) ($codeText) - $($probe.Message)" -ForegroundColor Red
    }
}

if ($failed) {
    Write-Host "Ingress networking reconciliation completed with probe failures." -ForegroundColor Yellow
    exit 1
}

Write-Host "Ingress networking reconciliation complete." -ForegroundColor Green
