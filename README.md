# 🛠️ Script PowerShell - Mise à jour Automatique des Pilotes via Windows Update

![Windows Update](https://img.shields.io/badge/Windows%20Update-Driver%20Upgrade-blue?style=for-the-badge&logo=windows&logoColor=white)

## 📖 Description
Ces scripts PowerShell **automatisent la mise à jour des pilotes** en utilisant **Windows Update**. Ils sont conçus pour être **déployés via GPO ou Snapin FOG Project**, permettant une exécution **silencieuse et sans intervention utilisateur**.

**Scripts disponibles :**
- `force_update_driversV2_pourGPO.ps1` : version orientée GPO avec transcript et nettoyage garanti.
- `force_update_driversV2bis.ps1` : version interactive affichant la liste des pilotes détectés.

## 🔥 Fonctionnalités
✅ **Télécharge et installe automatiquement** les pilotes depuis Windows Update.  
✅ **Compatible avec GPO et FOG Project** *(exécution en mode SYSTEM)*.  
✅ **Génère un fichier log** (`C:\Windows\Temp\DriverUpdateLog.txt`) pour suivre les mises à jour.  
✅ **Exécution en arrière-plan** *(aucune interaction requise)*.  
✅ **Suppression du service Microsoft Update** après exécution pour garder un système propre.  
✅ **Gestion d'erreurs stricte** (`Set-StrictMode`, `$ErrorActionPreference = 'Stop'`) pour éviter les échecs silencieux.  

---

## 📜 **Extrait du script (GPO)**
```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogFile = "C:\Windows\Temp\DriverUpdateLog.txt"
Start-Transcript -Path $LogFile -Append -Force

try {
    $UpdateSvc = New-Object -ComObject Microsoft.Update.ServiceManager
    $ServiceId = "7971f918-a847-4430-9279-4a52d1efe18d"
    $UpdateSvc.AddService2($ServiceId, 7, "") | Out-Null

    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $Searcher.ServiceID = $ServiceId
    $Searcher.SearchScope = 1
    $Searcher.ServerSelection = 3

    $Criteria = "IsInstalled=0 and Type='Driver'"
    $SearchResult = $Searcher.Search($Criteria)
    $Updates = $SearchResult.Updates

    if ($null -eq $Updates -or $Updates.Count -eq 0) {
        Write-Output "✅ Aucun pilote en attente de mise à jour."
        return
    }

    $UpdatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
    $Updates | ForEach-Object { $UpdatesToDownload.Add($_) | Out-Null }
    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $UpdatesToDownload
    $DownloadResult = $Downloader.Download()

    if ($DownloadResult.ResultCode -ne 2) {
        throw "Le téléchargement des mises à jour a échoué (ResultCode: $($DownloadResult.ResultCode))."
    }
} finally {
    if ($null -ne $UpdateSvc) {
        $UpdateSvc.Services | Where-Object { $_.IsDefaultAUService -eq $false -and $_.ServiceID -eq $ServiceId } | ForEach-Object {
            $UpdateSvc.RemoveService($_.ServiceID)
        }
    }
    Stop-Transcript
}
```

➡️ **Script complet** : `force_update_driversV2_pourGPO.ps1`
---

## 🚀 **Déploiement via GPO**
### **1️⃣ Ajouter le script dans une GPO**
1. **Copier le script** dans un partage réseau :  
   ```
   \\Serveur\Scripts\Maj_Pilotes_GPO.ps1
   ```
2. **Ouvrir `GPMC.msc`** et créer une **nouvelle GPO**.
3. Naviguer vers :
   ```
   Configuration Ordinateur > Stratégies > Paramètres Windows > Scripts (Démarrage)
   ```
4. **Ajouter le script PowerShell** en tant que script de démarrage.

### **2️⃣ Appliquer la GPO**
Sur un poste client, exécuter :
```powershell
gpupdate /force
```
Puis **redémarrer la machine**.

---

## 🎯 **Déploiement via FOG Project (Snapin)**
### **1️⃣ Ajouter le script en Snapin**
1. **Sauvegarder le script sous `Maj_Pilotes_FOG.ps1`**.
2. **Aller dans l'interface de FOG** et ajouter un **nouveau Snapin**.
3. **Paramétrer le Snapin** :
   - **Snapin Run With** : `powershell.exe`
   - **Snapin Run With Argument** : `-ExecutionPolicy Bypass -NoProfile -File`
   - **Snapin File** : `Maj_Pilotes_FOG.ps1`
   - **Reboot after install** : ✅ *(si nécessaire)*
   - **Snapin Enabled** : ✅

4. **Déployer le Snapin** sur les machines via FOG.

---

## 🔍 **Vérifications après exécution**
1️⃣ **Vérifier Windows Update**  
   - Aller dans **Paramètres > Windows Update** et voir si des pilotes ont été installés.  

2️⃣ **Vérifier le fichier log**  
   ```powershell
   Get-Content C:\Windows\Temp\DriverUpdateLog.txt
   ```
   Cela affichera **toutes les actions du script et les erreurs éventuelles**.

3️⃣ **Forcer une mise à jour manuelle** (si besoin) :
   ```powershell
   UsoClient.exe StartScan
   UsoClient.exe StartDownload
   UsoClient.exe StartInstall
   ```

---

## 📌 **Pourquoi utiliser ce script ?**
✔️ **Automatisation totale des mises à jour des pilotes**  
✔️ **Idéal pour les environnements entreprise (GPO, FOG Project)**  
✔️ **Facilement auditable grâce aux logs**  
✔️ **Sans intervention utilisateur (exécution silencieuse)**  

📢 **Tu as des idées d’améliorations ? Contribue au projet !** 😃  

---
🔗 **Auteur : [@Neosoda](https://github.com/neosoda)**  

---
