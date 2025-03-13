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
