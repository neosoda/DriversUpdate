# Définition du fichier log pour suivre l'exécution
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
