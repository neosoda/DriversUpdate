# DriversUpdate

Mise à jour **silencieuse et maîtrisée** des pilotes Windows 10/11 via l'API native Windows Update Agent (WUA). Script PowerShell 5.1, sans module tiers ni connexion à un service externe ajouté par le script.

**Entrée de déploiement :** force_update_drivers_gpo_hardened.ps1 (V2). Le nom est conservé pour les GPO déjà configurées.

## Principes de sécurité

- **Respecte les stratégies Windows Update/WSUS** : sélection du service WUA par défaut ; si la politique de source des pilotes est activée, sélection de Windows Update ou du serveur administré selon sa valeur. Aucun forçage systématique vers Microsoft Update.
- **Ne modifie pas les GPO, WSUS, ni les clés de stratégie.** Si la stratégie d'exclusion des pilotes est activée, le script s'arrête proprement (SkippedPolicy).
- **Par défaut, exclut** les pilotes des classes Firmware, Net, SCSIAdapter, HDC, DiskDrive et les titres contenant BIOS ou Firmware. Ces filtres conservateurs doivent être adaptés au parc.
- **Ne redémarre jamais automatiquement** le poste. Code de sortie 3010 si un redémarrage est nécessaire.
- **Exécution sans interaction**, en administrateur ou SYSTEM ; aucune élévation UAC et aucun mot de passe.
- **Verrou d'exécution global** pour éviter deux instances simultanées.
- **Modes audit sans installation** : ni téléchargement ni acceptation d'EULA.

> Les filtres sont heuristiques et ne remplacent pas une OU pilote ni les validations constructeur. Ils ne protègent pas des mises à jour lancées simultanément par d'autres programmes.

## Utilisation

Exemples depuis une console administrateur :

~~~powershell
# Inventaire sans installation
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1 -ScanOnly

# Simulation sans téléchargement
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1 -DryRun

# Installation autorisée par les filtres et les stratégies
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1

# Ignorer l'intervalle minimum
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1 -Force
~~~

ScanOnly et DryRun utilisent actuellement les mêmes règles de filtrage, mais consignent des modes différents dans l'état JSON.

### Configuration facultative

Placer le fichier C:\ProgramData\DriversUpdate\config.json (voir [config.example.json](config.example.json)) :

~~~json
{
  "ExcludedDriverClasses": ["Firmware", "Net", "SCSIAdapter", "HDC", "DiskDrive"],
  "ExcludedTitleContains": ["BIOS", "Firmware"],
  "IncludedTitleContains": []
}
~~~

Les comparaisons sont des **sous-chaînes insensibles à la casse**, pas des regex. Une liste IncludedTitleContains non vide crée une allowlist. Une liste d'exclusions vide retire les protections associées : à valider d'abord sur une OU pilote.

Paramètres : -ConfigPath, -LogRoot, -StateRoot, -MinimumScanIntervalHours 24 (défaut), -Force, -AcceptEula $false, -ScanOnly et -DryRun.

Le paramètre historique -TemporaryMicrosoftUpdateService est accepté pour compatibilité mais ignoré depuis la V2 : le script n'enregistre plus de service Microsoft Update.

### Déploiement GPO

1. **GPO ordinateur > Préférences > Paramètres Windows > Fichiers** : copier le script vers C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1.
2. **GPO ordinateur > Préférences > Tâches planifiées** : exécuter en NT AUTHORITY\SYSTEM avec autorisations maximales, au démarrage différé (15–60 minutes) et/ou chaque semaine, avec délai aléatoire.
3. Programme : %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
4. Arguments : -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1"
5. Tester sur une **OU pilote**, vérifier les stratégies WSUS, l'état JSON, les codes retour et l'absence de redémarrage automatique.

Si une GPO bloque les pilotes ou impose un WSUS qui n'en offre pas, le script ne contourne pas cette restriction.

## Observabilité

- Log local : C:\ProgramData\DriversUpdate\logs\deploy.log. Rotation à 5 Mo et trois archives.
- État : C:\ProgramData\DriversUpdate\state\state.json.
- DriverResults : noms, fabricants, classes, filtrages et résultats d'installation. Lisible par la supervision GLPI/Zabbix.
- Horodatages distincts : LastAttemptUtc, LastScanUtc, LastSuccessfulScanUtc, LastSuccessfulDeploymentUtc.
- Aucune exportation réseau automatique.

| Code | Signification |
| ---: | --- |
| 0 | Succès, aucun pilote ou exécution volontairement ignorée (voir LastOutcome) |
| 3010 | Succès, redémarrage requis |
| 100 / 101 / 102 / 103 | PowerShell / privilèges / architecture / prérequis |
| 110 / 120 / 130 / 140 | Échec scan / téléchargement / installation / partiel |
| 150 | Autre exécution déjà active |
| 160 | Conflit de stratégie Windows Update |
| 199 | Erreur inattendue |

## Tests et limites

Le workflow GitHub Actions exécute les tests de syntaxe et de logique isolée sous Windows PowerShell 5.1, ainsi que les erreurs PSScriptAnalyzer. La CI **ne teste pas** les appels COM Windows Update ni une véritable installation de pilotes. Validation sur postes GPO/SYSTEM/WSUS indispensable.

~~~powershell
powershell.exe -NoProfile -File .\tests\validate.ps1
~~~

Les deux anciens scripts force_update_driversV2_pourGPO.ps1 et force_update_driversV2bis.ps1 sont temporairement conservés pour compatibilité, mais **dépréciés**. Ne pas les utiliser pour de nouveaux déploiements.

Licence : MIT.
