# Week 9 - Let Git Drive Your Cluster with ArgoCD
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File .\week9.ps1
$ErrorActionPreference = "Stop"
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Shot($m) { Write-Host "`n[SCREENSHOT] $m" -ForegroundColor Yellow; Read-Host "Press Enter after taking it (Win+Shift+S)" | Out-Null }

Step "Checking tools"
foreach ($t in "docker", "minikube", "kubectl", "git") {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t is not installed or not on PATH" }
}

Step "Starting minikube"
minikube status *> $null
if ($LASTEXITCODE -ne 0) { minikube start --driver=docker }

Step "1. Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
Write-Host "Waiting for ArgoCD to come up (a few minutes)..."
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=900s

$b64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$pw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
Start-Process powershell -ArgumentList "-NoExit", "-Command", "kubectl port-forward svc/argocd-server -n argocd 8080:443"
Start-Sleep 6
Start-Process "https://localhost:8080"
Write-Host "ArgoCD UI : https://localhost:8080" -ForegroundColor Green
Write-Host "Username  : admin" -ForegroundColor Green
Write-Host "Password  : $pw" -ForegroundColor Green
Read-Host "Log in in the browser (accept the certificate warning), then press Enter" | Out-Null

Step "2. Creating the Application (repo k8s/ -> in-cluster, namespace default)"
kubectl apply -f argocd-app.yaml

Step "3. Manual sync"
Write-Host "In the UI open week9-app -> click SYNC -> SYNCHRONIZE. Waiting for Synced + Healthy..."
do {
  Start-Sleep 5
  $s = kubectl get application week9-app -n argocd -o jsonpath="{.status.sync.status} {.status.health.status}"
  Write-Host "  status: $s"
} until ($s -eq "Synced Healthy")
Shot "Screenshot 1: the week9-app page in ArgoCD showing Synced and Healthy"

Step "4. Enabling auto-sync"
kubectl patch application week9-app -n argocd --type merge --patch-file autosync-patch.json
kubectl get application week9-app -n argocd -o jsonpath="{.spec.syncPolicy}"; Write-Host ""

Step "5. BEFORE: replica count"
kubectl get deployment web -n default
kubectl get pods -n default -l app=web
Shot "Screenshot 2 (BEFORE): this window showing READY 2/2 and two pods"

Step "6. Changing replicas 2 -> 3 in Git (commit + push only)"
(Get-Content k8s\deployment.yaml) -replace 'replicas: 2', 'replicas: 3' | Set-Content k8s\deployment.yaml
git add k8s/deployment.yaml
git commit -m "Scale web deployment from 2 to 3 replicas"
git push
$commit = git rev-parse HEAD

Step "7. Waiting for ArgoCD to apply it on its own (no kubectl changes; polls Git ~every 3 min)"
$deadline = (Get-Date).AddMinutes(10)
do {
  Start-Sleep 15
  $ready = kubectl get deployment web -n default -o jsonpath="{.status.readyReplicas}"
  Write-Host ("  {0}  ready replicas: {1}" -f (Get-Date -Format HH:mm:ss), $ready)
} until ($ready -eq "3" -or (Get-Date) -gt $deadline)

Step "AFTER: replica count"
kubectl get deployment web -n default
kubectl get pods -n default -l app=web
$rev = kubectl get application week9-app -n argocd -o jsonpath="{.status.sync.revision}"
Write-Host "Pushed commit : $commit"
Write-Host "ArgoCD synced : $rev"
if ($rev -eq $commit) { Write-Host "ArgoCD deployed your commit automatically." -ForegroundColor Green }
Shot "Screenshot 3 (AFTER): this window showing READY 3/3 and three pods"
Write-Host "`nDone. Leave the port-forward window open if you want to keep using the UI." -ForegroundColor Green
