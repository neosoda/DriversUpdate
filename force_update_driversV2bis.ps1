$OutputEncoding = [System.Text.Encoding]::UTF8
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    # Ajouter le service Microsoft Update pour rechercher les pilotes tiers
    $UpdateSvc = New-Object -ComObject Microsoft.Update.ServiceManager
    $ServiceId = "7971f918-a847-4430-9279-4a52d1efe18d"
    $UpdateSvc.AddService2($ServiceId,7,"")

    # Créer une session Windows Update
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher() 
    $Searcher.ServiceID = $ServiceId
    $Searcher.SearchScope = 1  # Rechercher uniquement les mises à jour système
    $Searcher.ServerSelection = 3  # Activer les mises à jour de pilotes tiers

    # Définir le critère de recherche pour les pilotes
    $Criteria = "IsInstalled=0 and Type='Driver'"
    Write-Host('🔍 Recherche des mises à jour de pilotes...') -ForegroundColor Cyan   
    $SearchResult = $Searcher.Search($Criteria)          
    $Updates = $SearchResult.Updates

    # Vérification des mises à jour disponibles
    if ($null -eq $Updates -or $Updates.Count -eq 0) {
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
        $DownloadResult = $Downloader.Download()
        if ($DownloadResult.ResultCode -ne 2) {
            throw "Le téléchargement des mises à jour a échoué (ResultCode: $($DownloadResult.ResultCode))."
        }

        # Installer les mises à jour téléchargées
        $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        $updates | ForEach-Object { if ($_.IsDownloaded) { $UpdatesToInstall.Add($_) | Out-Null } }

        if ($UpdatesToInstall.Count -eq 0) {
            Write-Host "⚠️ Aucun pilote téléchargé n'est disponible pour l'installation." -ForegroundColor Yellow
            return
        }

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
    }

} catch {
    Write-Host "❌ Une erreur est survenue : $_" -ForegroundColor Red
    throw
} finally {
    if ($null -ne $UpdateSvc) {
        $updateSvc.Services | Where-Object { $_.IsDefaultAUService -eq $false -and $_.ServiceID -eq $ServiceId } | ForEach-Object {
            $UpdateSvc.RemoveService($_.ServiceID)
        }
    }
}
