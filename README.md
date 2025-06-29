# WindowsAutoConfig ⚙️

**Votre pilote automatique pour postes de travail Windows dédiés. Configurez une fois, et laissez le système s'autogérer en toute fiabilité.**

![Licence](https://img.shields.io/badge/Licence-GPLv3-blue.svg)
![Version PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Statut](https://img.shields.io/badge/Statut-Opérationnel-brightgreen.svg)
![OS](https://img.shields.io/badge/OS-Windows_10_|_11-informational)
![Contributions](https://img.shields.io/badge/Contributions-Bienvenues-brightgreen.svg)

---

## 🎯 Le Manifeste de WindowsAutoConfig

### Le Problème
Déployer et maintenir un ordinateur Windows pour une tâche unique (borne interactive, affichage dynamique, poste de commande) est un défi constant. Les mises à jour intempestives, les mises en veille inattendues, la nécessité de relancer manuellement une application après un redémarrage... Chaque détail peut devenir une source de panne et nécessite une intervention manuelle coûteuse en temps. Configurer chaque poste est un processus répétitif, long et sujet aux erreurs.

### La Solution : WindowsAutoConfig
**WindowsAutoConfig** transforme n'importe quel PC Windows en un automate fiable et prévisible. C'est un ensemble de scripts que vous installez localement et qui prend le contrôle de la configuration système pour garantir que votre machine fait exactement ce que vous attendez d'elle, 24h/24 et 7j/7.

Il agit comme un superviseur permanent, appliquant vos règles à chaque démarrage et à chaque ouverture de session, pour que vous n'ayez plus à le faire.

## ✨ Fonctionnalités Clés
*   **Assistant de Configuration Graphique :** Pas besoin d'éditer de fichiers pour les réglages de base.
*   **Gestion de l'Alimentation :** Désactivez la mise en veille de la machine, de l'écran, et le démarrage rapide de Windows pour une stabilité maximale.
*   **Connexion Automatique (Auto-Login) :** Gère l'auto-login, y compris en synergie avec l'outil **Sysinternals AutoLogon** pour une gestion sécurisée du mot de passe.
*   **Contrôle de Windows Update :** Empêchez les mises à jour et les redémarrages forcés de perturber votre application.
*   **Gestionnaire de Processus :** Lance, surveille et relance automatiquement votre application principale à chaque session.
*   **Redémarrage Quotidien Planifié :** Programmez un redémarrage quotidien pour maintenir la fraîcheur du système.
*   **Action Pré-Redémarrage :** Exécutez un script personnalisé (sauvegarde, nettoyage...) avant le redémarrage planifié.
*   **Journalisation Détaillée :** Toutes les actions sont enregistrées dans des fichiers journaux pour un diagnostic facile.
*   **Notifications (Optionnel) :** Envoyez des rapports de statut via Gotify.

---

## 🚀 Installation et Prise en Main
Mettre en place **WindowsAutoConfig** est un processus simple et guidé.

1.  **Téléchargez** ou clonez le projet sur l'ordinateur à configurer.
2.  Exécutez `1_install.bat`. Le script vous guidera à travers deux étapes :
    *   **Étape 1 : Configuration via l'Assistant Graphique.**
        Réglez les options selon vos besoins. Les plus importantes sont généralement l'identifiant pour la connexion automatique et l'application à lancer. Cliquez sur `Enregistrer` pour sauvegarder.
    *   **Étape 2 : Installation des Tâches Système.**
        Le script vous demandera une confirmation pour continuer. Une fenêtre de sécurité Windows (UAC) s'ouvrira. **Vous devez l'accepter** pour permettre au script de créer les tâches planifiées nécessaires.
3.  C'est terminé ! Au prochain redémarrage, vos configurations seront appliquées.

---

## 🔧 Configuration
Vous pouvez ajuster les paramètres à tout moment de deux manières :

### 1. Assistant Graphique (Méthode simple)
Relancez `1_install.bat` pour ouvrir à nouveau l'interface de configuration. Modifiez vos réglages et enregistrez.

### 2. Fichier `config.ini` (Méthode avancée)
Ouvrez `config.ini` avec un éditeur de texte pour un contrôle granulaire.

#### Note Importante sur l'Auto-Login et les Mots de Passe
Pour des raisons de sécurité, **WindowsAutoConfig ne gère et ne stocke jamais les mots de passe en clair.** Voici comment configurer l'auto-login de manière efficace et sécurisée :

*   **Scénario 1 : Le compte utilisateur n'a pas de mot de passe.**
    Indiquez simplement le nom d'utilisateur dans l'assistant graphique ou dans `AutoLoginUsername` du fichier `config.ini`.

*   **Scénario 2 : Le compte utilisateur a un mot de passe (Méthode recommandée).**
    1.  Téléchargez l'outil officiel **[Sysinternals AutoLogon](https://download.sysinternals.com/files/AutoLogon.zip)** de Microsoft (lien de téléchargement direct).
    2.  Lancez AutoLogon et renseignez le nom d'utilisateur, le domaine et le mot de passe. Cet outil stockera le mot de passe de manière sécurisée dans le Registre.
    3.  Dans la configuration de **WindowsAutoConfig**, vous pouvez maintenant laisser le champ `AutoLoginUsername` vide (le script détectera l'utilisateur configuré par AutoLogon) ou le renseigner pour être certain. Notre script s'assurera que la clé de Registre `AutoAdminLogon` est bien activée pour finaliser la configuration.

#### Configuration Avancée : `PreRebootActionCommand`
Cette fonctionnalité puissante vous permet d'exécuter un script avant le redémarrage quotidien. Le chemin d'accès peut être :
- **Absolu :** `C:\Scripts\mon_backup.bat`
- **Relatif au projet :** `PreReboot.bat` (le script cherchera ce fichier à la racine du projet).
- **Utilisant `%USERPROFILE%` :** `%USERPROFILE%\Desktop\cleanup.ps1` (le script remplacera intelligemment `%USERPROFILE%` par le chemin du profil de l'utilisateur de l'Auto-Login).

---

## 📂 Structure du Projet
```
WindowsAutoConfig/
├── 1_install.bat                # Point d'entrée pour l'installation et la configuration
├── 2_uninstall.bat              # Point d'entrée pour la désinstallation
├── config.ini                   # Fichier de configuration central
├── config_systeme.ps1           # Script principal pour les réglages machine (s'exécute au démarrage)
├── config_utilisateur.ps1       # Script principal pour la gestion du processus utilisateur (s'exécute au login)
├── PreReboot.bat                # Exemple de script pour l'action pré-redémarrage
├── Logs/                        # (Créé automatiquement) Contient les fichiers journaux
└── management/
    ├── firstconfig.ps1          # Le code de l'assistant de configuration graphique
    ├── install.ps1              # Le script technique d'installation des tâches
    └── uninstall.ps1            # Le script technique de suppression des tâches
```

---

## ⚙️ Fonctionnement Détaillé
Le cœur de **WindowsAutoConfig** repose sur le Planificateur de Tâches de Windows :

1.  **Au Démarrage de Windows**
    *   La tâche `WindowsAutoConfig_SystemStartup` s'exécute avec les droits `SYSTÈME`.
    *   Le script `config_systeme.ps1` lit `config.ini` et applique toutes les configurations machine. Il gère également la création/mise à jour des tâches de redémarrage.

2.  **À l'Ouverture de Session Utilisateur**
    *   La tâche `WindowsAutoConfig_UserLogon` s'exécute.
    *   Le script `config_utilisateur.ps1` lit la section `[Process]` de `config.ini` et s'assure que votre application principale est bien lancée. Si elle tournait déjà, elle est d'abord arrêtée puis relancée proprement.

3.  **Au Quotidien (Si configuré)**
    *   La tâche `WindowsAutoConfig_PreRebootAction` exécute votre script de sauvegarde/nettoyage.
    *   Quelques minutes plus tard, la tâche `WindowsAutoConfig_ScheduledReboot` redémarre l'ordinateur.

---

## 📄 Journalisation (Logging)
Pour un dépannage facile, tout est enregistré.
*   **Emplacement :** Dans le sous-dossier `Logs/`.
*   **Fichiers :** `config_systeme_ps_log.txt` et `config_utilisateur_log.txt`.
*   **Rotation :** Les anciens journaux sont automatiquement archivés pour éviter qu'ils ne deviennent trop volumineux.

---

## 🗑️ Désinstallation
Pour retirer le système :
1.  Exécutez `2_uninstall.bat`.
2.  **Acceptez la demande de privilèges (UAC)**.
3.  Le script supprimera proprement toutes les tâches planifiées créées par le projet.

**Note :** La désinstallation n'annule pas les changements système (ex: la veille restera désactivée) et ne supprime pas le dossier du projet.

---

## ❤️ Licence et Contributions
Ce projet est distribué sous la licence **GPLv3**. Le texte complet est disponible dans le fichier `LICENSE`.

Les contributions, que ce soit sous forme de rapports de bugs, de suggestions d'amélioration ou de "pull requests", sont les bienvenues.
