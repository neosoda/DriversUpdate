# 🛠️ Script PowerShell - Mise à jour Automatique des Pilotes via Windows Update

![Windows Update](https://img.shields.io/badge/Windows%20Update-Driver%20Upgrade-blue?style=for-the-badge&logo=windows&logoColor=white)

## 📖 Description
Ce projet contient des scripts PowerShell pour **automatiser la mise à jour des pilotes** en utilisant **Windows Update**. Vous y trouverez une version pour déploiement automatisé (GPO, FOG) et une version pour exécution manuelle.

## 🔥 Fonctionnalités Clés
✅ **Recherche, télécharge et installe automatiquement** les pilotes depuis Windows Update.
✅ **Deux versions disponibles** :
  - Une version **silencieuse** pour GPO/FOG avec **logs détaillés**.
  - Une version **interactive** pour exécution manuelle avec **suivi en temps réel**.
✅ **Nettoyage automatique** du service Microsoft Update après exécution.

---

## 📜 **1. Script pour GPO (Silencieux et avec logs)**
Ce script est conçu pour une exécution **totalement silencieuse**, idéale pour un déploiement via **GPO (Stratégie de groupe)** ou **FOG Project**. Toutes les actions sont enregistrées dans le fichier `C:\Windows\Temp\DriverUpdateLog.txt`.

Il correspond au fichier `force_update_driversV2_pourGPO.ps1`.
```powershell
# Définition du fichier log
$LogFile = "C:\Windows\Temp\DriverUpdateLog.txt"
Start-Transcript -Path $LogFile -Append -Force

try {
    Write-Output "🔍 Début du processus de mise à jour des pilotes via Windows Update..."

    # Ajouter le service Microsoft Update pour inclure les drivers tiers
    $UpdateSvc = New-Object -ComObject Microsoft.Update.ServiceManager
    $UpdateSvc.AddService2("7971f918-a847-4430-9279-4a52d1efe18d", 7, "") | Out-Null

    # Création de la session de mise à jour
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $Searcher.ServiceID = '7971f918-a847-4430-9279-4a52d1efe18d'
    $Searcher.SearchScope = 1  # Rechercher uniquement les mises à jour du système
    $Searcher.ServerSelection = 3  # Activer les mises à jour de pilotes tiers

    # Recherche des pilotes disponibles
    $Criteria = "IsInstalled=0 and Type='Driver'"
    Write-Output "🔎 Recherche des mises à jour de pilotes..."
    $SearchResult = $Searcher.Search($Criteria)
    $Updates = $SearchResult.Updates

    if ($Updates.Count -eq 0) {
        Write-Output "✅ Aucun pilote en attente de mise à jour."
    } else {
        Write-Output "⬇️ Téléchargement et installation des mises à jour détectées..."

        # Télécharger les pilotes
        $UpdatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        $Updates | ForEach-Object { $UpdatesToDownload.Add($_) | Out-Null }
        $Downloader = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $UpdatesToDownload
        $Downloader.Download()

        # Installer les pilotes téléchargés
        $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        $Updates | ForEach-Object { if ($_.IsDownloaded) { $UpdatesToInstall.Add($_) | Out-Null } }
        $Installer = $Session.CreateUpdateInstaller()
        $Installer.Updates = $UpdatesToInstall
        $InstallationResult = $Installer.Install()

        if ($InstallationResult.RebootRequired) {
            Write-Output "🔴 Un redémarrage est requis pour finaliser l'installation des pilotes."
        } else {
            Write-Output "✅ Installation des pilotes terminée avec succès."
        }
    }

    # Nettoyage du service Microsoft Update
    Write-Output "🧹 Nettoyage du service Microsoft Update..."
    $UpdateSvc.Services | Where-Object { $_.IsDefaultAUService -eq $false -and $_.ServiceID -eq "7971f918-a847-4430-9279-4a52d1efe18d" } | ForEach-Object {
        $UpdateSvc.RemoveService($_.ServiceID)
    }

} catch {
    Write-Output "❌ Une erreur est survenue : $_"
}

# Fin du script et arrêt du logging
Write-Output "🎯 Fin du processus de mise à jour des pilotes."
Stop-Transcript
```

---
## 📜 **2. Script Alternatif (Version Interactive)**
Ce script est une variante conçue pour une **exécution manuelle et interactive** dans une console PowerShell. Il affiche en temps réel les pilotes trouvés et la progression de l'installation avec des indicateurs colorés, mais **ne génère pas de fichier log**.

Idéal pour une utilisation ponctuelle ou pour du dépannage. Il correspond au fichier `force_update_driversV2bis.ps1`.

```powershell
$OutputEncoding = [System.Text.Encoding]::UTF8

# Ajouter le service Microsoft Update pour rechercher les pilotes tiers
$UpdateSvc = New-Object -ComObject Microsoft.Update.ServiceManager
$UpdateSvc.AddService2("7971f918-a847-4430-9279-4a52d1efe18d",7,"")

# Créer une session Windows Update
$Session = New-Object -ComObject Microsoft.Update.Session
$Searcher = $Session.CreateUpdateSearcher()
$Searcher.ServiceID = '7971f918-a847-4430-9279-4a52d1efe18d'
$Searcher.SearchScope = 1  # Rechercher uniquement les mises à jour système
$Searcher.ServerSelection = 3  # Activer les mises à jour de pilotes tiers

# Définir le critère de recherche pour les pilotes
$Criteria = "IsInstalled=0 and Type='Driver'"
Write-Host('🔍 Recherche des mises à jour de pilotes...') -ForegroundColor Cyan
$SearchResult = $Searcher.Search($Criteria)
$Updates = $SearchResult.Updates

# Vérification des mises à jour disponibles
if([string]::IsNullOrEmpty($Updates)) {
    Write-Host "✅ Aucun pilote en attente de mise à jour."
} else {
    # Afficher les pilotes disponibles
    $Updates | Select Title, DriverModel, DriverVerDate, Driverclass, DriverManufacturer | Format-List

    # Télécharger les mises à jour détectées
    $UpdatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
    $updates | ForEach-Object { $UpdatesToDownload.Add($_) | Out-Null }
    Write-Host('⬇️ Téléchargement des mises à jour de pilotes...') -ForegroundColor Yellow
    $UpdateSession = New-Object -ComObject Microsoft.Update.Session
    $Downloader = $UpdateSession.CreateUpdateDownloader()
    $Downloader.Updates = $UpdatesToDownload
    $Downloader.Download()

    # Installer les mises à jour téléchargées
    $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    $updates | ForEach-Object { if ($_.IsDownloaded) { $UpdatesToInstall.Add($_) | Out-Null } }

    Write-Host('⚙️ Installation des pilotes en cours...') -ForegroundColor Green
    $Installer = $UpdateSession.CreateUpdateInstaller()
    $Installer.Updates = $UpdatesToInstall
    $InstallationResult = $Installer.Install()

    # Vérifier si un redémarrage est requis
    if ($InstallationResult.RebootRequired) {
        Write-Host('🔴 Redémarrage requis ! Veuillez redémarrer le système.') -ForegroundColor Red
    } else {
        Write-Host('✅ Installation des pilotes terminée avec succès !') -ForegroundColor Green
    }

    # Nettoyer le service Microsoft Update ajouté
    $updateSvc.Services | Where-Object { $_.IsDefaultAUService -eq $false -and $_.ServiceID -eq "7971f918-a847-4430-9279-4a52d1efe18d" } | ForEach-Object {
        $UpdateSvc.RemoveService($_.ServiceID)
    }
}
```

---

## 🚀 **Déploiement (GPO & FOG)**
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
