<div align="center">

<img src="assets/readme-hero.svg" alt="DriversUpdate — mise à jour des pilotes Windows sous contrôle" width="100%">

<br>

[![CI PowerShell](https://github.com/neosoda/DriversUpdate/actions/workflows/powershell-ci.yml/badge.svg?branch=main)](https://github.com/neosoda/DriversUpdate/actions/workflows/powershell-ci.yml)
![Windows 10 et 11](https://img.shields.io/badge/Windows-10%20%7C%2011-087CD9?logo=windows11&logoColor=white)
![Windows PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-3979C6?logo=powershell&logoColor=white)
[![Licence MIT](https://img.shields.io/badge/Licence-MIT-36BDA8)](LICENSE)

### Des pilotes Windows à jour. Sans perdre le contrôle.

**Un moteur Windows Update, deux façons de l'utiliser :** une console manuelle claire, entièrement en français, et un déploiement automatisé par GPO.

**Aucun module tiers · Stratégies Windows Update/WSUS respectées · Aucun redémarrage automatique**

[**Utilisation manuelle**](#-utilisation-manuelle) · [**Déploiement GPO**](#-déploiement-par-gpo) · [**Configuration**](#-filtres-et-sécurité) · [**Diagnostic**](#-journaux-et-supervision)

</div>

---

## 🧭 Quel script utiliser ?

| Script | Pour qui ? | Comportement |
| :--- | :--- | :--- |
| **[DriversUpdate-Manual.ps1](DriversUpdate-Manual.ps1)** | Technicien, administrateur, intervention sur un poste | Console **en français**, recherche, choix individuel des pilotes, confirmation avant installation et bilan lisible. |
| **[force_update_drivers_gpo_hardened.ps1](force_update_drivers_gpo_hardened.ps1)** | Parc informatique, GPO, tâche planifiée, compte SYSTEM | Moteur **sans interaction**, pilotable par paramètres, logs, état JSON et codes retour. |

**Il n'y a que deux scripts de lancement.** Le mode manuel appelle le même moteur que la GPO : pas de logique d'installation dupliquée.

> [!IMPORTANT]
> Le moteur peut installer des pilotes sans confirmation lorsqu'il est lancé directement en mode automatique. **Pour intervenir manuellement sur un poste, utilisez `DriversUpdate-Manual.ps1`.** Validez les installations sur un poste pilote avant toute généralisation.

## 🚀 Utilisation manuelle

### Installation et lancement

Prérequis : **Windows 10 ou 11**, **Windows PowerShell 5.1**, droits **administrateur** et accès à la source de mises à jour autorisée par les stratégies de la machine.

~~~powershell
git clone https://github.com/neosoda/DriversUpdate.git
cd DriversUpdate

# Depuis une console Windows PowerShell ouverte en administrateur
powershell.exe -NoProfile -File .\DriversUpdate-Manual.ps1
~~~

Sans Git, téléchargez les deux scripts depuis le dépôt et placez-les **dans le même dossier**. La console manuelle a besoin du moteur à ses côtés.

### À quoi ressemble le menu ?

~~~text
========================================================
   DRIVERSUPDATE  |  GESTION DES PILOTES WINDOWS
========================================================
  Ordinateur : MON-PC
  Autorisations : administrateur

  QUE VOULEZ-VOUS FAIRE ?

  [1] Rechercher les pilotes disponibles
      Consulter uniquement, sans rien installer.

  [2] Choisir les pilotes à installer
      Sélection puis confirmation obligatoire.

  [3] Afficher le dernier bilan
  [4] Consulter le journal technique
  [0] Quitter
~~~

La console affiche les **pilotes détectés**, ceux **autorisés** et ceux **exclus**, avec une explication. Elle présente ensuite un bilan en français : date, machine, résultat, pilotes installés et éventuel besoin de redémarrage. Le journal technique conserve les détails nécessaires au dépannage.

### Rechercher sans installer

Choisissez **1**. DriversUpdate interroge Windows Update, applique les filtres et affiche les résultats.

**Aucun pilote n'est téléchargé ni installé**, et aucune licence n'est acceptée. L'outil peut toutefois démarrer les services Windows Update nécessaires et écrit son journal et son état local.

### Choisir et installer des pilotes

Choisissez **2**. Le parcours est guidé :

1. **Recherche** des pilotes proposés par la source Windows Update ou WSUS configurée.
2. **Sélection** parmi les pilotes autorisés (les pilotes exclus ne peuvent pas être choisis).
3. **Récapitulatif et confirmation** avant téléchargement et installation.

~~~text
  ÉTAPE 2/3 - CHOIX DES PILOTES

  [1] Pilote audio                       AUTORISÉ
  [2] Pilote réseau                      EXCLU
  [3] Pilote périphérique USB            AUTORISÉ

  Numéros à installer : 1,3

  ÉTAPE 3/3 - VÉRIFICATION AVANT INSTALLATION

  2 pilotes sélectionnés
  Tapez INSTALLER pour confirmer :
~~~

<sub>Exemple illustratif : les noms de pilotes et exclusions dépendent de la machine.</sub>

| Saisie | Résultat |
| :--- | :--- |
| `1,3` | Sélectionne les pilotes 1 et 3. |
| `1-3` | Sélectionne une plage, **seulement si tous les pilotes sont autorisés**. |
| `T` | Sélectionne tous les pilotes autorisés. |
| `0` ou Entrée vide | Annule l'installation. |
| `?` | Rappelle l'aide à la saisie. |

**Seule la saisie exacte de `INSTALLER` autorise le téléchargement et l'installation.** Une autre réponse annule l'opération. Un redémarrage peut être nécessaire après installation, mais le programme ne le déclenche jamais automatiquement.

## 🏫 Déploiement par GPO

Pour l'automatisation, utilisez **uniquement `force_update_drivers_gpo_hardened.ps1`**, sans l'interface manuelle.

### Fonctionnement recommandé

~~~mermaid
flowchart LR
    A["GPO / tâche planifiée<br/>SYSTEM"] --> B["Windows Update Agent"]
    B --> C{"Stratégies WSUS/WU<br/>et filtres"}
    C -->|"Exclu ou bloqué"| D["Journal + état JSON"]
    C -->|"Autorisé"| E["Téléchargement<br/>et installation"]
    E --> D
    classDef main fill:#18354E,stroke:#4A9CCC,color:#FFFFFF;
    classDef safe fill:#174A43,stroke:#4FBFA8,color:#FFFFFF;
    class A,B,E main;
    class C,D safe;
~~~

**Déploiement conseillé :** distribuer le script sur le disque local, puis l'exécuter via une **tâche planifiée GPO sous `NT AUTHORITY\SYSTEM`**, avec les privilèges les plus élevés.

1. Dans **Configuration ordinateur → Préférences → Paramètres Windows → Fichiers**, copiez le moteur vers `C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1`.
2. Dans **Configuration ordinateur → Préférences → Paramètres du Panneau de configuration → Tâches planifiées**, créez une tâche sous **SYSTEM**.
3. Utilisez un déclenchement **différé de 15 à 60 minutes** après le démarrage et, si souhaité, une récurrence hebdomadaire avec délai aléatoire.
4. Déployez d'abord sur une **OU pilote**, contrôlez les exclusions, les journaux et les besoins de redémarrage, puis étendez le périmètre.

**Programme :**

~~~text
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
~~~

**Arguments :**

~~~text
-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\DriversUpdate\force_update_drivers_gpo_hardened.ps1"
~~~

Le moteur conserve un intervalle minimal de **24 heures après un déploiement réussi**, sauf utilisation du paramètre `-Force`. Un **mutex** empêche deux exécutions concurrentes.

> [!WARNING]
> DriversUpdate **respecte les stratégies Windows Update et WSUS**. Il n'essaie pas de contourner une GPO qui exclut les pilotes, ni de basculer automatiquement vers Internet lorsqu'un serveur WSUS ne propose pas de pilotes.

## 🛡️ Filtres et sécurité

Les exclusions suivantes sont actives par défaut :

| Type | Exclusion |
| :--- | :--- |
| **Classes de pilotes** | `Firmware`, `Net`, `SCSIAdapter`, `HDC`, `DiskDrive` |
| **Mots-clés du titre** | `BIOS`, `Firmware` |
| **Interaction utilisateur** | Pilotes nécessitant une intervention ou dont cette propriété ne peut pas être vérifiée |
| **Source des mises à jour** | Celle autorisée par les stratégies Windows Update/WSUS |

La configuration est **facultative**. Pour modifier les filtres, copiez [config.example.json](config.example.json) vers `C:\ProgramData\DriversUpdate\config.json` :

~~~json
{
  "ExcludedDriverClasses": ["Firmware", "Net", "SCSIAdapter", "HDC", "DiskDrive"],
  "ExcludedTitleContains": ["BIOS", "Firmware"],
  "IncludedTitleContains": []
}
~~~

`IncludedTitleContains` est une liste d'autorisation : non vide, elle limite les pilotes à ceux dont le titre contient au moins un terme indiqué. Les comparaisons sont **insensibles à la casse** et recherchent des sous-chaînes, **pas des expressions régulières**.

> [!CAUTION]
> Dans le JSON, un tableau vide **remplace** le filtre par défaut correspondant : `"ExcludedDriverClasses": []` supprime donc les exclusions de classes. À n'utiliser qu'après validation.

## ⚙️ Exécution avancée

Les commandes suivantes concernent le **moteur GPO**, et non la console à menu.

~~~powershell
# Audit sans installation ni téléchargement
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1 -ScanOnly

# Simulation : même sélection que l'audit, résultat enregistré comme simulation
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1 -DryRun

# Installation automatique de tous les pilotes éligibles (sans confirmation)
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1

# Ignore uniquement le délai de 24 h, pas les stratégies ni les filtres
powershell.exe -NoProfile -File .\force_update_drivers_gpo_hardened.ps1 -Force
~~~

| Paramètre | Utilité |
| :--- | :--- |
| `-ScanOnly` | Recherche et filtre sans télécharger ni installer. |
| `-DryRun` | Simulation sans télécharger ni installer. |
| `-Interactive` | Sélection manuelle avec confirmation (console locale interactive uniquement). |
| `-UserFacing` | Affichage destiné à l'utilisateur ; utilisé par le lanceur manuel. |
| `-Force` | Ignore l'intervalle entre deux déploiements réussis. |
| `-MinimumScanIntervalHours` | Intervalle de déploiement, **24 h** par défaut. |
| `-ConfigPath` | Chemin du fichier JSON. |
| `-LogRoot` / `-StateRoot` | Dossiers des journaux et de l'état. |
| `-AcceptEula` | `$true` par défaut pour les installations éligibles. |
| `-TemporaryMicrosoftUpdateService` | Paramètre historique accepté mais **ignoré** : le script n'enregistre pas Microsoft Update. |

En mode manuel, la confirmation `INSTALLER` intervient **avant** toute acceptation de licence, téléchargement ou installation. En mode automatique, l'installation suit les paramètres et les filtres sans demander d'avis à l'utilisateur.

## 📋 Journaux et supervision

Les données restent **locales** : aucun serveur de collecte ni télémétrie spécifique n'est ajouté par DriversUpdate.

~~~text
C:\ProgramData\DriversUpdate\
├── config.json             # Facultatif
├── logs\
│   ├── deploy.log          # Journal courant
│   └── deploy.log.1 à .3   # Archives
└── state\
    └── state.json          # Dernier bilan, exploitable en supervision
~~~

- **`deploy.log` :** logs détaillés, rotation à **5 Mo**, trois archives.
- **`state.json` :** date, mode, source, résultat, pilotes détectés/installés, éventuel redémarrage et détail par pilote.
- **Codes retour :** pour les tâches planifiées, GLPI, Zabbix ou d'autres outils d'exploitation.

~~~powershell
# Consulter les 50 dernières lignes du journal
Get-Content "$env:ProgramData\DriversUpdate\logs\deploy.log" -Tail 50

# Lire l'état JSON pour une supervision
Get-Content "$env:ProgramData\DriversUpdate\state\state.json" -Raw |
    ConvertFrom-Json |
    Select-Object LastOutcome, LastExitCode, UpdatesFound, UpdatesInstalled, RebootRequired
~~~

<details>
<summary><strong>Voir les codes de retour</strong></summary>

| Code | Signification |
| ---: | :--- |
| **0** | Réussite, recherche seule, annulation volontaire ou opération ignorée ; consulter `LastOutcome`. |
| **3010** | Installation terminée, **redémarrage nécessaire**. |
| 100 / 101 / 102 | Version PowerShell non prise en charge / droits insuffisants / relance 64 bits impossible. |
| 103 | Prérequis, configuration ou console interactive invalide. |
| 110 / 120 / 130 | Échec de recherche / téléchargement / installation. |
| 140 | Résultat partiel. |
| 150 | Une autre exécution est déjà active. |
| 160 | Conflit de stratégies Windows Update. |
| 199 | Erreur inattendue. |

</details>

## 🔍 Diagnostic rapide

| Symptôme | À vérifier |
| :--- | :--- |
| **Aucun pilote proposé** | Stratégies d'exclusion, source WSUS/WU, filtres JSON et connectivité de la machine. |
| **Pilote indiqué « Exclu »** | Catégorie ou mot-clé protégé, interaction requise, licence ou liste d'autorisation. |
| **L'interface refuse de démarrer** | Présence des deux fichiers dans le même dossier, console locale et droits administrateur. |
| **Code 3010** | Planifier un redémarrage adapté au poste : aucun redémarrage automatique. |
| **Messages techniques en anglais** | Normal dans `deploy.log` ; le menu et le bilan sont présentés en français. |

## ✅ Tests et compatibilité

Le workflow [PowerShell CI](.github/workflows/powershell-ci.yml) vérifie la **syntaxe des deux scripts**, les filtres et sélections, la gestion de l'état JSON, ainsi que les erreurs **PSScriptAnalyzer** sur **Windows PowerShell 5.1**.

~~~powershell
# Exécuter les tests localement, sans installer de pilotes
powershell.exe -NoProfile -File .\tests\validate.ps1
~~~

Ces tests utilisent des scénarios isolés : **ils ne prouvent pas l'installation réelle de pilotes via l'API COM Windows Update**. Un essai sur poste pilote reste indispensable avant le déploiement sur un parc.

---

<div align="center">

**Pour les administrateurs qui veulent automatiser sans sacrifier la maîtrise.**

Créé par [**neosoda**](https://github.com/neosoda) · [Licence MIT](LICENSE)

[⭐ Soutenir le projet](https://github.com/neosoda/DriversUpdate/stargazers) · [🐛 Signaler un problème](https://github.com/neosoda/DriversUpdate/issues) · [🔧 Proposer une amélioration](https://github.com/neosoda/DriversUpdate/pulls)

</div>
