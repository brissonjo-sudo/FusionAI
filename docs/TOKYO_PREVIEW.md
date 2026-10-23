# FusionAI — essai Delphi 10.2 Tokyo

Version source : `v3.1.1-tokyo-preview.1`. Base amont :
`52888477aa3ae3d7396301cc086c7614d62212d2`.

Cette branche contient des corrections issues d'une lecture du code. **La compilation
Delphi et l'exécution dans l'IDE ne sont pas encore validées. Aucun BPL compilé n'est
fourni.** Les tests Python vérifient uniquement le serveur simulé.

## Premier essai sur Windows

1. Télécharger cette branche (bouton **Code → Download ZIP**) et extraire le ZIP.
2. Fermer les projets importants ; désinstaller/désactiver l'ancien FusionAI ou
   ChatGPTWizard avant d'installer ce package. Conserver son ancien BPL pour revenir
   en arrière. Sauvegarder l'historique SQLite avant d'essayer cette branche.
3. Dans l'invite de commandes **RAD Studio 10.2**, exécuter `tests\build.cmd`.
   Le résultat attendu est `PASS: requests, responses, Pascal masking, comments and Windows DPAPI`.
   Ce programme compile les unités corrigées de protocole, texte et secrets ; il
   n'éprouve pas l'IDE, le HTTP, le parseur complet ou FireDAC. **Ce PASS ne garantit
   pas que le package compile** : l'étape 4 reste indispensable.
4. Ouvrir `FusionAI.dproj` dans Delphi 10.2, sélectionner **Win32**, puis **Build**.
   Si les métadonnées du projet amont sont refusées, ouvrir `FusionAI.dpk` et laisser
   Delphi créer ses options de projet ; ajouter `Forms`, `Utils` et `Lexer` au chemin
   de recherche. Ne pas installer un BPL construit pour une autre version de Delphi.
5. Installer le package construit avec **Install** dans le gestionnaire de projets.
   Si Build échoue, transmettre la première erreur exacte et le numéro de version
   10.2.x : cette erreur est nécessaire avant de déclarer la compatibilité acquise.

Les packages requis sont ceux de l'amont : ToolsAPI/designide, VCL, Indy, REST et
FireDAC SQLite, fournis par l'installation Delphi correspondante. Aucun SDK LLM tiers
n'est ajouté.

## Essai sans API payante

Python 3 n'est nécessaire que pour ce serveur de test ; le plugin n'en dépend pas.

```console
python tests/mock_provider.py --scenario success
```

Dans les réglages du plugin, activer **Ollama uniquement**, choisir le modèle
`test-model` et l'URL `http://127.0.0.1:8765`. Laisser la clé vide. Poser une question :
la réponse doit contenir une accolade fermante, du pseudo-code et une deuxième ligne.
L'action dans l'éditeur doit afficher une prévisualisation, puis insérer chaque ligne
en commentaire `//` après confirmation. Vérifier **Annuler**, puis **Ctrl+Z**.

Pour éprouver les autres adaptateurs avec ce même serveur, utiliser les réglages de
la table. Le champ de clé des fournisseurs cloud doit contenir la valeur factice
`fixture-only`, jamais une vraie clé pour ce test HTTP local. Désactiver le proxy.

| Fournisseur | URL de base du simulateur | Modèle d'essai |
|---|---|---|
| ChatGPT | `http://127.0.0.1:8765/v1` | `gpt-4o-mini`, puis `o3` |
| Claude | `http://127.0.0.1:8765` | `test-model` |
| Gemini | `http://127.0.0.1:8765/v1beta` | `test-model` |
| Ollama | `http://127.0.0.1:8765` | `test-model` |

Claude doit afficher tous les blocs texte, y compris `tail`, sans afficher le bloc
`thinking`. **Refresh** doit remplir la liste des modèles tout en laissant les
réglages réactifs et en conservant le modèle déjà saisi.

Relancer le serveur, un scénario à la fois :

```console
python tests/mock_provider.py --scenario truncated
python tests/mock_provider.py --scenario truncated_empty
python tests/mock_provider.py --scenario error429
python tests/mock_provider.py --scenario empty
python tests/mock_provider.py --scenario slow --delay 15
```

- `truncated` : signaler une réponse incomplète, conserver le texte partiel à examiner,
  ne pas l'insérer automatiquement comme un succès.
- `truncated_empty` : budget épuisé sans texte (cas d'un modèle reasoning). Les quatre
  adaptateurs doivent afficher « Incomplete response », jamais « empty response ».
- `error429` : afficher `HTTP 429` et le message de quota simulé.
- `empty` : afficher un échec explicite.
- `slow` : essayer Stop, une nouvelle question, puis fermer le panneau pendant la
  requête. L'ancienne réponse ne doit pas remplacer la nouvelle ni réapparaître.
  Fixer le timeout à 5 secondes pour éprouver aussi l'expiration.

Pour le contexte des classes : modifier une méthode **sans enregistrer**, rester
sur la même unité puis lancer une action Class View. Vérifier la présence du nouveau
texte dans le prompt envoyé au simulateur avec un débogueur, ou dans le journal local
activé pour cet essai. Un fichier syntaxiquement incomplet doit pouvoir rendre une
sélection indisponible, mais ne doit pas provoquer de boucle infinie.

Le simulateur ne reproduit ni TLS, ni proxy, ni limites réelles des fournisseurs. Il
n'effectue aucun appel extérieur. Le choix d'un modèle accessible au compte reste
nécessaire pour un essai réel. Les valeurs déjà enregistrées restent conservées :
changer manuellement un ancien modèle retiré dans les réglages.

## Changements et limites

| Audit | Traitement dans cette branche |
|---|---|
| F01 — modèles retirés | Nouveaux défauts Gemini/Claude ; configurations existantes conservées. |
| F02 — paramètres incompatibles | OpenAI classique/reasoning séparés ; sampling omis pour Claude. Les identifiants OpenAI inconnus suivent le profil reasoning : à vérifier pour un endpoint personnalisé. |
| F03 — réponse qui ferme un commentaire | Prévisualisation et commentaires ligne par ligne ; insertion annulable, après la fin de la ligne cible (jamais au milieu d'une ligne). |
| F04 — threads oubliés après Stop | Requêtes marquées annulées, workers conservés jusqu'à leur fin, résultats obsolètes ignorés, jonction à la destruction. Annulation réseau coopérative seulement. |
| F05 — blocs Claude perdus | Tous les blocs `text` sont concaténés ; absence de texte signalée. |
| F06 — pointeur temporaire et EOF | Chaîne source conservée durant la vie du lexer ; gardes de fin de fichier. |
| F07 — troncature | Raisons de fin usuelles détectées dans les quatre adaptateurs. |
| F08 — objets perdus | Settings, réponses, workers et dictionnaires du panneau ont un propriétaire explicite. Pas encore de mesure de fuite native. |
| F09 — lecture du fichier disque | Buffer courant prioritaire ; relecture lors d'une action sur une classe. |
| F10 — mots-clés dans chaînes/identifiants | Chaînes et commentaires masqués ; mots-clés entiers. Le parseur reste heuristique. |
| F11 — Refresh bloquant / proxy oublié | Réseau dans un worker ; proxy copié ; timeout HTTP de listing plafonné à 20 s. |
| F12 — cache fragile | Types JSON contrôlés, cache invalide ignoré, remplacement atomique du fichier. Échec de sauvegarde du cache non bloquant. |
| F13 — mauvais prompt dans l'historique | Prompt capturé dans la réponse, utilisé pour l'enregistrement. |
| F14 — section critique non libérée | `try/finally` dans `EditorViewActivated`. |
| F15 — secrets en clair dans le registre | DPAPI Windows à la sauvegarde ; champs masqués. Une valeur non déchiffrable est vidée et signalée, sans remettre les autres réglages à zéro. Lire la limite de migration ci-dessous. |
| F16 — clé Ollama ignorée | En-tête Bearer optionnel pour génération et listing ; URL normalisée avec/sans `/api`. |

Correctifs issus d'une seconde revue :

| Constat | Traitement |
|---|---|
| Onglet History inutilisable | Le `.dfm` ne déclare que 4 champs persistants ; les colonnes ajoutées par le schéma 3 sont créées à l'ouverture à partir des définitions de la requête. |
| Menus restant dans l'IDE après désinstallation | Les items FusionAI sont retirés du menu contextuel de l'éditeur à la libération du crochet. |
| Budget de sortie emprunté à ChatGPT | Sans limite propre, Gemini laisse le défaut du modèle et Claude utilise 16 000 ; Ollama garde la limite commune, son défaut étant sans borne. Sur le point d'accès officiel, un modèle reasoning OpenAI reçoit 25 000 tant que la limite commune vaut son défaut historique (2048) ; une valeur choisie, un modèle `-chat` ou un serveur compatible gardent la valeur réglée. Ce sont des plafonds : le timeout HTTP (60 s par défaut, 120 s au plus) peut couper une très longue réponse avant. |

Scénarios IDE associés : ouvrir l'onglet **History** sur une base existante, puis
filtrer par fournisseur et modèle. Désinstaller le package, faire un clic droit dans
l'éditeur : aucun item FusionAI ne doit rester. Placer le curseur au milieu d'une
ligne puis lancer **Add Comments** : la ligne doit rester intacte, les commentaires
apparaissent dessous.

L'historique passe au schéma 3 dans une transaction. Le remplissage des anciennes
colonnes se fait une seule fois, au lieu de réécrire toute la table à chaque ouverture.
Aucun gain de temps n'a été mesuré sur une base réelle.

**Stop** retire immédiatement la requête du lot affiché et positionne un drapeau
contrôlé par le callback HTTP. Avant la réception de données, Tokyo peut attendre le
timeout réseau. Fermer/désinstaller le plugin attend la fin des workers afin de ne
pas décharger leur code encore exécuté ; l'IDE peut donc attendre à ce moment. Les
timeouts HTTP sont des délais réseau, pas une garantie de durée totale de bout en
bout. Stop ne garantit pas l'annulation côté fournisseur ou l'arrêt de la facturation.
Le nombre de workers conservés est limité pour éviter une accumulation de retries.

Les secrets sont chiffrés pour l'utilisateur Windows courant lors du prochain **Save**.
Les anciennes valeurs en clair restent lisibles pour la migration ; une copie dans
l'ancienne racine `HKCU\SOFTWARE\ChatGPTWizard` ou une sauvegarde n'est pas effacée.
Ne pas réutiliser cette configuration chiffrée avec un autre profil Windows : une
valeur illisible est laissée vide, les réglages s'ouvrent avec un avertissement qui la
nomme, et le **Save** suivant la remplace. Il faut alors la ressaisir. DPAPI
ne protège pas contre un programme exécuté avec les mêmes droits utilisateur.
L'historique et les journaux restent des fichiers locaux non chiffrés contenant du
code et des prompts lorsque ces fonctions sont activées.

Le parseur n'est pas un compilateur Pascal : routines imbriquées, commentaires
imbriqués, compilation conditionnelle et sources partiellement écrites nécessitent
encore des essais. Le chat reste sans mémoire conversationnelle transmise à l'API ;
le streaming et les reprises automatiques ne sont pas ajoutés.

## Vérifications effectuées ici

- 5 tests Python du **simulateur** : formes JSON, catalogues, paramètres rejetés,
  troncature et erreur HTTP.
- Contrôle de whitespace avec `git diff --check` et lecture XML du projet.
- Vérification des références aux unités ajoutées dans le package et le projet.
- Revue manuelle des chemins de succès, erreur, annulation et destruction.

**À exécuter sur Windows :** `tests\build.cmd`, compilation complète Win32,
installation dans Tokyo, scénarios IDE ci-dessus, test proxy/TLS et essai réel avec
un modèle accessible. Ces validations restent ouvertes.

## Références de conception

Les défauts de modèles et les restrictions de paramètres évoluent ; vérifier les
catalogues du fournisseur avant un déploiement durable.

- [Amont FusionAI](https://github.com/AliDehbansiahkarbon/FusionAI)
- [OpenAI — modèles récents](https://developers.openai.com/api/docs/guides/latest-model)
- [Gemini — dépréciations](https://ai.google.dev/gemini-api/docs/deprecations)
- [Claude — dépréciations](https://platform.claude.com/docs/en/about-claude/model-deprecations)
- [Microsoft — CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)

La licence MIT et les attributions de l'amont sont conservées.
