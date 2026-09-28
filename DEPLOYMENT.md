# Guide de Déploiement et Préparation Testnet — Protocole TON Tontine V1

Ce document détaille l'architecture opérationnelle, les procédures de simulation, la gouvernance de sécurité et les protocoles de vérification pour le déploiement contrôlé d'un contrat `TontineCircle` sur l'environnement TON Testnet via **Acton 1.2.0**.

---

## A. Émulation Locale (Local Emulation)

Par défaut, l'outillage Acton s'exécute entièrement au sein de l'émulateur TVM local :
- Aucune transaction n'est diffusée sur un réseau décentralisé (`net.isBroadcasting() == false`).
- Aucun portefeuille réel, seed phrase ou fonds réels ne sont requis.
- L'intégrité de la compilation et la validité du storage initial sont testées instantanément.

### Commande de simulation locale :
```bash
TONTINE_CIRCLE_ID=1 \
TONTINE_USDT_MASTER=kQD___________________________________________Bi \
TONTINE_PROTOCOL_TREASURY=kQD___________________________________________Bi \
acton script contracts/scripts/deploy.tolk
```

Ou via le raccourci Acton :
```bash
acton run deploy-emulation
```

---

## B. Préflight Testnet Read-Only (Testnet Fork Preflight)

Le script `contracts/scripts/preflightTestnet.tolk` est conçu pour exécuter un dry-run strict en lecture seule sur l'état du Testnet :
- Il s'exécute avec `--fork-net testnet` (résolution des comptes distants sans broadcast).
- Il ne requiert **JAMAIS** `--net`.
- Il accepte l'adresse réelle du `controller` prévu (`TONTINE_CONTROLLER_ADDRESS`) et ne la remplace pas par un portefeuille fictif d'émulateur.
- Il réutilise `buildInitialTontineStorage(...)` et `TontineCircle.fromStorage(...)`, garantissant un calcul d'adresse et de `StateInit` rigoureusement identique au futur broadcast.

### Commande de Préflight :
```bash
TONTINE_CIRCLE_ID=1 \
TONTINE_CONTROLLER_ADDRESS=<ADRESSE_CONTROLLER_TESTNET> \
TONTINE_USDT_MASTER=<ADRESSE_JETTON_MASTER_TESTNET> \
TONTINE_PROTOCOL_TREASURY=<ADRESSE_TREASURY_TESTNET> \
acton script contracts/scripts/preflightTestnet.tolk --fork-net testnet
```

Ou via l'alias sécurisé :
```bash
acton run deploy-testnet-dry-run
```

> [!NOTE]
> **Disponibilité du Fork Distant :**
> L'exécution avec `--fork-net testnet` dépend de la connectivité réseau et de la latence des passerelles RPC TON Center. Si un timeout réseau distant survient lors d'une tentative de fork, la logique de préflight et la compilation restent validées localement, mais l'exécution en direct doit être relancée dès disponibilité du réseau distant.

### Comportement Strictement Bloquant du Préflight :
Le préflight distingue formellement les types de contrôles :
1. **CRITICAL CHECKS (Bloquants) :** Tout échec entraîne immédiatement un résultat **`PRE-FLIGHT RESULT: NO-GO`** et lève une exception (code 301). Le script ne produit jamais de faux succès :
   - Validité des workchains du controller, master et treasury (`0` ou `-1`).
   - Validité de l'intervalle uint64 pour `circleId`.
   - Absence de collision d'adresse (`!scripts.isContractDeployed(targetAddress)`).
   - Déploiement effectif du contrat Jetton Master (`scripts.isContractDeployed(usdtMaster)`).
   - Réactivité du getter TEP-74 `get_jetton_data` du Jetton Master.
   - Réactivité du getter TEP-89 `get_wallet_address(controller)` du Jetton Master.
   - Présence et lisibilité du code déployé du Jetton Master.
   - **Vérifications d'Empreinte et d'Admin Fail-Closed :**
     - Si `TONTINE_EXPECTED_MASTER_CODE_HASH` est défini :
       - Valeur malformée (non parsable en entier/hex) $\implies$ **CRITICAL FAIL (NO-GO immédiat)**.
       - Valeur non concordante avec le code hash observé on-chain $\implies$ **CRITICAL FAIL (NO-GO immédiat)**.
       - Valeur concordante $\implies$ **CRITICAL PASS**.
       - Non configuré $\implies$ rappel explicite de contrôle manuel hors-chaîne (`[MANUAL CHECK]`).
     - Si `TONTINE_EXPECTED_JETTON_ADMIN` est défini :
       - Adresse malformée (syntaxe non reconnue) $\implies$ **CRITICAL FAIL (NO-GO immédiat)**.
       - Admin on-chain nul ou différent de l'adresse attendue $\implies$ **CRITICAL FAIL (NO-GO immédiat)**.
       - Adresse concordante $\implies$ **CRITICAL PASS**.
       - Non configuré $\implies$ rappel explicite de contrôle manuel hors-chaîne (`[MANUAL CHECK]`).
2. **WARNINGS (Seuils Opérationnels) :**
   - Solde du Controller : le seuil de 0.2 TON est un **seuil opérationnel indicatif** configuré pour le préflight et ne constitue en aucun cas une garantie de couverture des coûts gaz réels du réseau. Si le solde est inférieur, un avertissement explicite est émis sans bloquer le diagnostic.
3. **MANUAL CHECKS (Vérifications Obligatoires Hors-Chaîne) :**
   - Si tous les contrôles critiques automatisés passent, le préflight conclut par **`PRE-FLIGHT RESULT: GO FOR MANUAL REVIEW`** (et non un GO direct pour broadcast), rappelant que la possession du contrôleur, la gouvernance de la trésorerie et la conformité de l'empreinte du master doivent être validées manuellement par l'opérateur.

---

## C. Préparation du Jetton de Test (Tontine Test Jetton / USDTT)

Le protocole ne doit pas dépendre d'un token tiers non maîtrisé sur Testnet. Les tests utilisent un Jetton dédié dont le nom officiel est standardisé en **`Tontine Test Jetton`** (symbole **`USDTT`**) conforme TEP-74 / TEP-89 pour éliminer toute ambiguïté avec le véritable USDT Tether.

### Convention d'Affichage et Unités Comptables (6 Décimales) :
Le contrat Jetton manipule des montants entiers et n'impose pas mathématiquement un diviseur. L'indication « 6 décimales » est une **convention de métadonnées et d'affichage** :
- `1 USDTT` = $1\,000\,000$ unités entières.
- Cotisation d'un tour : `20_000_000` unités = 20 USDTT.
- Caution personnelle : `40_000_000` unités = 40 USDTT.

### Borne Exacte des Pièces (`coins`) et Prévention d'Overflow :
Dans le standard TVM / Acton, le type `coins` (VarUInteger16) impose la borne stricte :
$$0 \le X \le 2^{120} - 1$$
Soit :
$$\text{MAX\_COINS} = 1329227995784915872903807060280344575$$
La valeur $2^{120} = 1329227995784915872903807060280344576$ excède la capacité de sérialisation TL-B et est **strictement rejetée** avant tout transtypage (`validateMintAmount`).
Par ailleurs, le script vérifie la contrainte cumulative de supply total (`canMintWithoutSupplyOverflow`) :
$$\text{initialSupply} \le \text{MAX\_COINS} - \text{amount}$$
garantissant l'absence totale de dépassement après émission.

### 1. Déploiement du Jetton Master de Test (`USDTT`)
Le script `contracts/scripts/deployTestJetton.tolk` déploie une instance propre de `JettonMinter` avec métadonnées onchain (nom `Tontine Test Jetton`, symbole `USDTT`, convention 6 décimales, URI `https://tontine.finance/usdtt.json`) :
```bash
acton script contracts/scripts/deployTestJetton.tolk
```
- Affiche explicitement `Network mode: LOCAL EMULATION` en local, ou `Expected network: TESTNET` lors d'un broadcast.
- Vérifie post-déploiement : `totalSupply == 0`, `mintable == true`, `adminAddress == admin.address`, présence du bytecode de wallet et dérivation de l'adresse du wallet admin.

### 2. Émission Contrôlée de Jettons de Test (Mint)
Le script `contracts/scripts/mintTestJetton.tolk` applique un pipeline rigoureux en **16 étapes ordonnées** avant tout envoi :
1. Parsing de l'adresse du minter.
2. Parsing de l'adresse du destinataire.
3. Validation des workchains (basechain `0` ou masterchain `-1`).
4. Parsing du montant en tant qu'entier `int`.
5. Validation $amount > 0$.
6. Validation $amount \le \text{MAX\_COINS}$ ($2^{120}-1$) avant tout cast vers `coins`.
7. Vérification que le minter est effectivement déployé on-chain.
8. Interrogation des données on-chain du minter (`get_jetton_data`).
9. Vérification que le signataire correspond exactement à `adminAddress`.
10. Lecture du `initialSupply`.
11. Vérification $\text{initialSupply} \le \text{MAX\_COINS}$.
12. Vérification d'absence de dépassement cumulatif ($\text{initialSupply} + amount \le \text{MAX\_COINS}$).
13. Affichage du récapitulatif détaillé.
14. Vérification de l'acquittement d'opt-in si broadcast réel.
15. Confirmation interactive explicite (défaut `false`).
16. Transtypage sécurisé vers `coins` et construction des messages internes.

```bash
TONTINE_USDT_MASTER=<ADRESSE_MINTER> \
TONTINE_MINT_RECIPIENT=<ADRESSE_MEMBRE> \
TONTINE_MINT_AMOUNT=100000000 \
acton script contracts/scripts/mintTestJetton.tolk
```

### Vérification Objective Post-Mint :
1. `sendRes.waitForTrace()` attend la trace descendante complète (transaction racine et messages internes vers le `JettonWallet`).
2. Le `totalSupply` est ensuite relu on-chain depuis le `JettonMinter` via `get_jetton_data()`.
3. Plusieurs relectures immédiates (jusqu'à 5 tentatives) peuvent être effectuées si la valeur n'est pas immédiatement reflétée.
4. **Précision importante sur l'exécution :** ces relectures sont séquentielles et immédiates ; elles ne constituent **pas** une attente temporelle, un sleep ou un backoff temporisé.
5. Le message **`MINT VERIFIED SUCCESSFULLY`** n'est émis que si la condition mathématique stricte `postSupply == initialSupply + amount` est confirmée.
6. Le principal risque résiduel de cette étape est un faux négatif (erreur 607) si l'API getter accuse un léger retard d'indexation immédiatement après la disponibilité de la trace.

### 3. Fiche d'Identité Approuvée du Master Jetton
L'opérateur consigne et archive l'identité du Master Jetton déployé :
- **Nom du Token :** `Tontine Test Jetton`
- **Symbole :** `USDTT`
- **Adresse Master :** Adresse workchain standard (`kQC...`)
- **Réseau :** TON Testnet
- **Contrôleur / Admin :** Adresse du compte administrateur du minter
- **Convention Décimales :** `6` (convention d'affichage, comptabilité en entiers)
- **Metadata URI :** `https://tontine.finance/usdtt.json`
- **Code Hash :** Empreinte SHA256 du code TVM compilé (ex: `0xf771572bf3f147dfad0a607da2a4db2c23ccf32f8d8e2a2b2cb1c8474de1f0c4`)
- **Date & Version :** Date de mise en service et commit Git source

---

## D. Grille de Décision GO / NO-GO

Tout futur broadcast Testnet est strictement **NO-GO** si l'un quelconque des critères ci-dessous n'est pas validé :

| Point de Contrôle | Type de Vérification | Statut Requis pour GO |
| :--- | :---: | :--- |
| `acton build` & `acton test` | AUTOMATED | 100% PASS (125/125 tests) |
| Git Working Tree propre | AUTOMATED | Aucun diff imprévu, commit certifié |
| `circleId` $\in [0, 2^{64}-1]$ | AUTOMATED | Entier non négatif validé |
| Workchains adresses (0 ou -1) | AUTOMATED | Basechain ou Masterchain validée |
| Adresse Tontine vierge | AUTOMATED | Aucun contrat préalablement déployé à l'adresse calculée |
| Master Jetton déployé et réactif | AUTOMATED | Contrat présent, `get_jetton_data` et `get_wallet_address` opérationnels |
| Empreinte Master Jetton (si configurée) | AUTOMATED (Fail-Closed) | Code hash strictement identique à `TONTINE_EXPECTED_MASTER_CODE_HASH` |
| Admin Master Jetton (si configuré) | AUTOMATED (Fail-Closed) | Admin on-chain strictement identique à `TONTINE_EXPECTED_JETTON_ADMIN` |
| Acquittement d'opt-in de broadcast | AUTOMATED | `TONTINE_ALLOW_TESTNET_BROADCAST` exacte |
| Confirmation interactive | AUTOMATED / MANUAL | Accord explicite (`true`), défaut à `false` |
| Égalité Controller préflight / broadcast | MANUAL | `TONTINE_CONTROLLER_ADDRESS` préflight == adresse exacte du wallet utilisé |
| Contrôle du Controller | MANUAL | Portefeuille sous contrôle physique effectif de l'équipe |
| Empreinte du Master Jetton (hors auto) | MANUAL | Code hash observé comparé à l'empreinte archivée du `JettonMinter` |
| Contrôle de la Trésorerie | MANUAL | Adresse vérifiée conforme à la gouvernance/multisig protocolaire |
| Réseau ciblé | MANUAL | Vérification formelle de la connexion Testnet |

---

## E. Diffusion Réelle sur Testnet — ÉTAPE MANUELLE FUTURE

> [!CAUTION]
> **Aucun broadcast ne doit être déclenché pendant la phase de durcissement.**
> Le broadcast réel constitue une étape opérationnelle future, réalisée uniquement après accord formel.

Lors de la phase de broadcast effectif, le déploiement utilise les launchers contrôlés dans `scripts/` :
- Pour TontineCircle : `scripts/deploy-testnet.sh` (Bash) ou `scripts/deploy-testnet.ps1` (PowerShell).
- Pour le Jetton de test : `scripts/deploy-test-jetton.sh` / `.ps1` et `scripts/mint-test-jetton.sh` / `.ps1`.

### Sécurité et Allow-List des Launchers :
Les launchers appliquent une validation stricte :
1. **Acquittement d'opt-in (phrase publique documentée) :**
   Exige `TONTINE_ALLOW_TESTNET_BROADCAST="I_UNDERSTAND_THIS_IS_A_REAL_TESTNET_BROADCAST"`.
2. **Imposition littérale du réseau :** Le paramètre `--net testnet` est codé en dur ; toute tentative d'injection d'un argument contenant `--net` ou `--fork-net` est immédiatement rejetée.
3. **Allow-list stricte des options autorisées :** Seules les options indispensables sont acceptées :
   - `--tonconnect`
   - `--explorer <nom>` (valeurs autorisées par Acton : `actonscan`, `tonscan`, `toncx`, `dton`, `tonviewer`).
   Tout autre argument entraîne l'arrêt immédiat avec message d'erreur.
4. **Transmission sécurisée :** Aucun recours à `eval` ou `Invoke-Expression`.

### Barrières Internes au Script Tolk :
- **Barrière A :** Vérification de l'opt-in `TONTINE_ALLOW_TESTNET_BROADCAST`.
- **Barrière B :** Affichage d'un récapitulatif solennel avec `REAL BROADCAST: YES`, rappel du réseau attendu, paramètres et adresse calculée.
- **Barrière C :** Confirmation interactive `confirm(..., false, ...)` dont la valeur par défaut est `false`. En mode non-interactif, aucune transaction ne peut être émise.

---

## F. Utilisation de TonConnect (Recommandée pour Opérateur Humain)

Pour un déploiement humain sans manipuler de clés privées sur la machine locale :
- Exécution avec `--tonconnect` :
  ```bash
  ./scripts/deploy-testnet.sh --tonconnect
  ```
- Un QR code ou un lien universel s'affiche dans le terminal pour approbation depuis un portefeuille mobile compatible (Tonkeeper, Tonhub en mode Testnet).
- Aucune phrase mnémonique n'est stockée dans le répertoire du projet.
- Les fichiers de session sont enregistrés sous `build/sessions/tonconnect/`, répertoire déjà exclu du suivi Git via `.gitignore`.
- **Rappel de sécurité :** TonConnect sécurise la signature de la transaction, mais ne protège pas contre une erreur de paramétrage initial. L'opérateur doit vérifier manuellement que l'adresse du compte connecté correspond exactement à `TONTINE_CONTROLLER_ADDRESS`.

---

## G. Vérification Post-Déploiement

Dès confirmation de la transaction on-chain, les assertions post-déploiement interrogent automatiquement les getters de l'instance déployée :
- `lastOperationQueryId() == 0`
- `circleJettonWalletResolved() == false`
- `circleJettonWalletLookupPending() == false`
- `state() == 1` (`STATE_OPEN`)
- `currentRound() == 0`
- `memberCount() == 10`
- `registeredCount() == 0`
- `fundedBondCount() == 0`
- `roundCollected() == 0`
- `protocolFeesAccrued() == 0`

> [!WARNING]
> **Caractère Non-Atomique :** Les assertions post-déploiement permettent de détecter une anomalie d'état après coup, mais ne peuvent pas annuler une transaction déjà inscrite sur la blockchain. D'où la primauté absolue du préflight et des barrières pré-broadcast.

Une fois ces getters vérifiés, l'opérateur procède à l'étape suivante : déclenchement de la résolution du wallet via `BeginCircleJettonWalletResolution` (`0x52434A57`).

---

## H. Procédure d'Incident (Incident Handling)

Si une transaction est diffusée avec une mauvaise configuration (mauvaise trésorerie, mauvais master, circleId erroné) :
1. **Arrêt immédiat :** Ne pas procéder à l'onboarding des membres et ne financer aucun cautionnement sur cette instance.
2. **Aucune tentative de mutation :** Le protocole ne comporte aucune fonction de modification administrative de son storage initial.
3. **Abandon officiel :** Déclarer publiquement l'instance comme abandonnée et consigner son adresse dans le registre des incidents.
4. **Correction et Redéploiement :** Rectifier les variables de configuration, relancer le préflight pour obtenir la nouvelle adresse calculée, puis procéder à un déploiement neuf.

---

## I. Limitation et Exclusion du Réseau Mainnet

- **Constat d'audit :** L'outillage Acton 1.2.0 expose `net.isBroadcasting()`, mais n'expose pas d'API Tolk publique fournissant le nom du réseau d'exécution (`testnet` vs `mainnet`).
- **Garantie opérationnelle :** Le script de déploiement ne peut donc pas bloquer techniquement `--net mainnet` de façon programmatique au niveau du compilateur.
- **Règle stricte :** L'interdiction du Mainnet repose sur les launchers contrôlés qui forcent `--net testnet`, la mention explicite `TESTNET` dans la phrase d'opt-in obligatoire et les procédures de gouvernance. Aucun déploiement Mainnet ne doit être réalisé dans ce cadre.
