# DriversUpdate

Scripts PowerShell pour rechercher, telecharger et installer silencieusement les mises a jour de pilotes disponibles via l'API Windows Update.

Le script recommande pour un deploiement entreprise est :

```text
force_update_drivers_gpo_hardened.ps1
```

Il est concu pour une execution non interactive en contexte machine, idealement via une tache planifiee creee par GPO et executee en `NT AUTHORITY\SYSTEM`.

## Objectif

- Deploiement silencieux sur postes Windows 10 et Windows 11.
- Execution compatible GPO, sans session utilisateur ouverte.
- Pas de contournement UAC ni d'elevation interactive.
- Journalisation locale dans `C:\ProgramData\DriversUpdate\logs\deploy.log`.
- Etat local dans `C:\ProgramData\DriversUpdate\state\state.json`.
- Execution relancable sans effet de bord.
- Codes retour exploitables par GPO, supervision ou inventaire.

## Scripts

| Fichier | Usage |
| --- | --- |
| `force_update_drivers_gpo_hardened.ps1` | Version recommandee pour GPO, tache planifiee SYSTEM et deploiement silencieux. |
| `force_update_driversV2_pourGPO.ps1` | Ancienne version GPO conservee pour reference. |
| `force_update_driversV2bis.ps1` | Ancienne version interactive, non recommandee pour GPO. |

## Mode de deploiement recommande

Utiliser une tache planifiee deployee par GPO ordinateur.

Ce mode est preferable a un script de demarrage pur, car il permet :

- un demarrage differe apres l'ouverture reseau et la stabilisation des services Windows Update ;
- une execution recurrente controlee ;
- un historique d'execution dans le Planificateur de taches ;
- une execution en `SYSTEM` sans mot de passe ;
- une reduction de l'impact sur le temps de demarrage.

## Configuration GPO conseillee

### 1. Copier le script localement

Chemin GPO :

```text
Configuration ordinateur
 > Preferences
 > Parametres Windows
 > Fichiers
```

Action : `Mettre a jour`

Source exemple :

```text
\\domaine.local\SYSVOL\domaine.local\scripts\DriversUpdate\force_update_drivers_gpo_hardened.ps1
```

Destination :

```text
C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1
```

### 2. Creer la tache planifiee

Chemin GPO :

```text
Configuration ordinateur
 > Preferences
 > Parametres du Panneau de configuration
 > Taches planifiees
```

Parametres recommandes :

```text
Nom : DriversUpdate - Windows Update Drivers
Compte : NT AUTHORITY\SYSTEM
Executer avec les autorisations maximales : Oui
Executer que l'utilisateur soit connecte ou non : Oui
Configure pour : Windows 10 ou ulterieur
```

Declencheurs recommandes :

```text
Au demarrage
Delai : 15 a 60 minutes
```

Optionnel :

```text
Declencheur hebdomadaire
Delai aleatoire : 1 a 4 heures
```

Action :

```text
Programme :
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe

Arguments :
-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1"
```

## Parametres utiles

```powershell
-Force
```

Force une recherche meme si une execution reussie recente existe.

```powershell
-MinimumScanIntervalHours 24
```

Evite de rescanner trop souvent. Valeur par defaut : `24`.

```powershell
-AcceptEula $true
```

Accepte les EULA des mises a jour Windows Update. Valeur par defaut : `$true`.

```powershell
-TemporaryMicrosoftUpdateService
```

Supprime le service Microsoft Update uniquement si le script l'a ajoute pendant cette execution. Non recommande par defaut en environnement entreprise, car Microsoft Update peut etre une configuration voulue.

## Codes retour

| Code | Signification |
| ---: | --- |
| `0` | Succes, aucune mise a jour, ou execution ignoree car recente. |
| `3010` | Succes avec redemarrage requis. |
| `100` | Version PowerShell non supportee. |
| `101` | Execution non privilegiee. |
| `102` | Probleme d'architecture ou de relance PowerShell 64 bits. |
| `103` | Prerequis non satisfait. |
| `110` | Echec de recherche Windows Update. |
| `120` | Echec de telechargement. |
| `130` | Echec d'installation. |
| `140` | Succes partiel. |
| `199` | Erreur inattendue. |

## Tests manuels

Verifier la syntaxe :

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  "C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1",
  [ref]$null,
  [ref]$errors
) | Out-Null
$errors
```

Execution manuelle depuis une console administrateur :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1" -Force -MinimumScanIntervalHours 0
echo $LASTEXITCODE
```

Execution en contexte `SYSTEM` avec PsExec :

```cmd
psexec.exe -accepteula -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1" -Force -MinimumScanIntervalHours 0
```

Consulter les journaux :

```powershell
Get-Content "C:\ProgramData\DriversUpdate\logs\deploy.log" -Tail 100
Get-Content "C:\ProgramData\DriversUpdate\state\state.json" -Raw
```

## Procedure de validation avant deploiement massif

1. Creer une OU pilote avec quelques postes Windows 10 et Windows 11.
2. Lier la GPO a cette OU uniquement.
3. Verifier que le script est bien copie dans `C:\ProgramData\DriversUpdate`.
4. Verifier que la tache planifiee s'execute en `NT AUTHORITY\SYSTEM`.
5. Controler `deploy.log`, `state.json`, le code retour et l'historique de la tache.
6. Confirmer le comportement en cas de redemarrage requis avec le code `3010`.
7. Verifier les politiques Windows Update/WSUS : si l'acces a Microsoft Update est bloque, le script journalise l'echec mais ne peut pas telecharger les pilotes.
8. Etendre progressivement le ciblage GPO avec un delai aleatoire pour eviter les pics de charge.

## Notes d'exploitation

- Ne pas lancer le script dans un contexte utilisateur standard.
- Ne pas ajouter de logique UAC interactive.
- Ne pas stocker de mot de passe : utiliser le compte `SYSTEM`.
- Eviter l'execution trop frequente ; conserver un intervalle minimal de scan.
- Surveiller les codes retour `120`, `130` et `140` pour detecter les problemes Windows Update ou pilotes.
