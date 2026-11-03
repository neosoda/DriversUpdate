<div align="center">

<img src="assets/readme-hero.svg" alt="DriversUpdate — gestion des pilotes Windows" width="100%">

# DriversUpdate

**Deux scripts PowerShell 5.1 indépendants. Aucun module externe, aucun JSON de configuration.**

Windows 10/11 · Windows Update Agent · GPO / SYSTEM · Console manuelle en français · Proxy authentifié facultatif

</div>

## Deux fichiers, deux usages

| Script | Utilisation |
| --- | --- |
| [force_update_drivers_gpo_hardened.ps1](force_update_drivers_gpo_hardened.ps1) | **GPO ou tâche planifiée SYSTEM**, totalement silencieux et sans session utilisateur |
| [DriversUpdate-Manual.ps1](DriversUpdate-Manual.ps1) | **Exécution manuelle**, menu français, choix des pilotes et confirmation obligatoire |

**Chaque PS1 fonctionne tout seul.** Téléchargez le fichier correspondant et lancez-le sans copier l'autre. Les fonctions de recherche/installations sont embarquées dans les deux scripts, afin qu'ils restent réellement indépendants.

Ils respectent les politiques Windows Update et WSUS, ne forcent **jamais le redémarrage**, conservent les exclusions des pilotes sensibles (réseau, stockage, firmware...) et écrivent des logs / un état local.

## Proxy : tout dans le PS1

En début de **chaque fichier**, éditez les variables suivantes :

~~~powershell
$ProxyEnabled = $true                    # false : WinHTTP de la machine
$ProxyHost = '172.17.0.1'
$ProxyPort = 3128
$ProxyBypassList = '<local>'
$ProxyUser = 'UTILISATEUR'
$ProxyPassword = 'MOT_DE_PASSE'
$ProxyAuthScheme = 'Basic'
~~~

Remplacez les **deux valeurs fictives** par les identifiants réels uniquement dans **la copie locale déployée**. Le script refuse les valeurs de démonstration lorsque le proxy est activé. Si le proxy n'exige aucune authentification, laissez les deux chaînes vides.

- **GPO** : proxy activé par défaut, à compléter avant déploiement. Compatible SYSTEM sans session utilisateur.
- **Manuel** : proxy désactivé par défaut ; changez ProxyEnabled en true uniquement si nécessaire.
- L'outil sauvegarde la configuration WinHTTP, définit un proxy machine temporaire, transmet les identifiants à WinHTTP et essaie le proxy de session WUA. En fin de traitement, il restaure WinHTTP et ses paramètres. Après interruption brutale, il essaie de récupérer une sauvegarde lors du prochain lancement.

> [!CAUTION]
> Un mot de passe inscrit dans un PS1 est **visible en clair** par quiconque peut lire le fichier, y compris dans les partages GPO/SYSVOL. **Ne commitez jamais des identifiants réels dans ce dépôt public** et ne stockez jamais une copie contenant des secrets dans un partage lisible par les utilisateurs du domaine. Distribuez une copie locale avec des ACL strictes SYSTEM / Administrateurs et des accès restreints à la source de distribution. Pour un grand parc, un proxy acceptant l'identité machine ou une règle d'accès Windows Update sans mot de passe est plus sûr. Aucun encodage Base64 n'apporte de protection.

## Déploiement GPO

Copiez **uniquement** le fichier GPO sur les machines, dans un répertoire local réservé aux administrateurs, par exemple :

~~~text
C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1
~~~

Créez une tâche planifiée via GPO sous **NT AUTHORITY\SYSTEM**, avec les privilèges les plus élevés. Privilégiez un déclenchement différé après démarrage pour laisser le réseau et les services Windows Update se stabiliser.

~~~text
Programme : %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
Arguments : -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1"
~~~

Exécution pilote **sans téléchargement ni installation** :

~~~powershell
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1 -ScanOnly -Force
~~~

Options : -ScanOnly, -DryRun, -Force, -MinimumScanIntervalHours (24 h par défaut), -LogRoot, -StateRoot et -AcceptEula. Un mutex empêche les déploiements concurrents.

## Lancement manuel

Téléchargez **uniquement** [DriversUpdate-Manual.ps1](DriversUpdate-Manual.ps1) sur le poste. Depuis Windows PowerShell lancé en administrateur :

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\DriversUpdate-Manual.ps1
~~~

Menu disponible :

~~~text
[1] Rechercher les pilotes disponibles (sans installation)
[2] Choisir les pilotes à installer (confirmation : INSTALLER)
[3] Afficher le dernier bilan
[4] Consulter le journal technique
[0] Quitter
~~~

L'installation manuelle demande de **choisir les pilotes autorisés**, puis de confirmer explicitement avant tout téléchargement. Les pilotes exclus restent exclus.

## Logs et supervision

Les fichiers suivants sont générés **à l'exécution**, pas nécessaires au déploiement :

~~~text
C:\ProgramData\DriversUpdate\
├── logs\
│   └── deploy.log
└── state\
    ├── state.json
    └── proxy\            # Sauvegarde temporaire WinHTTP ; récupération après interruption
~~~

~~~powershell
Get-Content "$env:ProgramData\DriversUpdate\logs\deploy.log" -Tail 50
Get-Content "$env:ProgramData\DriversUpdate\state\state.json" -Raw | ConvertFrom-Json |
    Select-Object LastOutcome, LastExitCode, UpdatesFound, UpdatesInstalled, RebootRequired
netsh winhttp show proxy
~~~

Codes retour principaux : 0 (succès / ignoré, consulter LastOutcome), 3010 (redémarrage requis, non automatique), 103 (configuration / prérequis), 110 (recherche), 120 (téléchargement), 130 (installation), 140 (partiel), 150 (exécution concurrente), 160 (stratégies contradictoires).

## Vérifications

~~~powershell
.\tests\validate.ps1
~~~

Les tests utilisent les fonctions Windows PowerShell (sans télécharger ni installer de pilotes). **Le comportement réel sous SYSTEM et avec proxy authentifié doit être vérifié sur un poste pilote** avant déploiement massif.

Licence MIT.
