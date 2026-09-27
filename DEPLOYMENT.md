# Guide de Déploiement Canonique — Protocole TON Tontine V1

Ce document décrit la procédure officielle, reproductible et documentée pour déployer un contrat `TontineCircle` sur la blockchain TON à l'aide de l'outillage officiel **Acton** (v1.2.0).

---

## 1. Prérequis d'Environnement et Modalités d'Exécution

- **Acton CLI** : Version `1.2.0` installée (`acton --version`).
- **Langage** : Tolk (compilateur embarqué Acton).
- **Modes d'Exécution du Script** :
  - **Émulation locale (par défaut)** :
    Exécuter simplement :
    ```bash
    acton script contracts/scripts/deploy.tolk
    ```
    Sans argument `--net`, le script s'exécute exclusivement au sein de l'émulateur TVM local. Aucun portefeuille réel, clé privée ou fonds on-chain ne sont requis.
  - **Diffusion Réseau (Broadcast)** :
    Pour diffuser réellement une transaction sur un réseau TON externe, l'argument `--net` doit être explicitement fourni (ex: `--net testnet`). Un portefeuille TON configuré via Acton (`acton wallet`) ou une connexion TON Connect (`--tonconnect`) approvisionné d'au moins **0.2 à 0.5 TON** est alors nécessaire.

> [!WARNING]
> **Règle Opérationnelle concernant le Mainnet** :
> Le script de déploiement ne bloque **pas techniquement** l'argument `--net mainnet`. Cependant, dans le cadre de ce chantier de durcissement pré-audit, l'interdiction de déploiement sur le Mainnet constitue une **règle opérationnelle et procédurale stricte**, et non une barrière imposée par le code du script. Aucun broadcast sur le réseau principal ne doit être réalisé à ce stade.

---

## 2. Rôles et Paramètres de Déploiement

Le script officiel [`contracts/scripts/deploy.tolk`](file:///c:/Users/DELL%20WORKSTATION/Projects/tontine-protocol-v1/contracts/scripts/deploy.tolk) requiert exactement **4 paramètres variables** :

| Paramètre | Type | Rôle et Responsabilité Opérationnelle |
| :--- | :---: | :--- |
| `circleId` | `uint64` | Entier non négatif représentable sur uint64 ($0 \le \text{circleId} \le 2^{64}-1$). Son unicité éventuelle relève d'une responsabilité métier/off-chain et n'est pas vérifiée par le script. |
| `controller` | `address` | Adresse administratrice officielle du cercle (gouvernance, enregistrement des membres, déclenchement des tours). Résolue automatiquement via le portefeuille sélectionné par l'opérateur (`deployer.address`). |
| `usdtMaster` | `address` | Adresse fournie par l'opérateur et devant correspondre au Jetton Master USDT attendu (TEP-74 / TEP-89). Son authenticité et son bytecode doivent être vérifiés opérationnellement avant broadcast. |
| `protocolTreasury` | `address` | Adresse fournie par l'opérateur et devant correspondre à la trésorerie opérationnelle voulue du protocole (destinataire des frais de 2.5%). Son contrôle effectif doit être vérifié avant broadcast. |

### Responsabilité Opérationnelle de l'Opérateur et Notion de Confiance
Le script de déploiement vérifie que les adresses fournies pour `usdtMaster` et `protocolTreasury` sont syntaxiquement valides au sens d'Acton et appartiennent à une workchain autorisée (`0` ou `-1`).

Cependant, le script **ne peut en aucun cas prouver ni garantir automatiquement** :
- que l'adresse saisie pour le Master Jetton est le véritable contrat USDT officiel émis par Tether ;
- que le contrat déployé à cette adresse possède le code et le comportement Jetton standard attendus ;
- que l'adresse de trésorerie appartient bien au protocole et se trouve sous le contrôle de ses administrateurs ;
- qu'aucune erreur matérielle ou faute de frappe n'a été commise lors de la transmission d'une adresse par ailleurs valide.

Une fois déployé, le contrat `TontineCircle` authentifie les messages entrants (réponses TEP-89, notifications de transfert, etc.) **relativement aux adresses initialement configurées**. La responsabilité de choisir et vérifier ces adresses en amont incombe donc intégralement à l'opérateur.

### Transmission des Paramètres
- **Variables d'environnement** :
  - `TONTINE_CIRCLE_ID` : Entier non négatif dans l'intervalle $[0, 2^{64}-1]$.
  - `TONTINE_USDT_MASTER` : Adresse fournie par l'opérateur pour le Jetton Master USDT.
  - `TONTINE_PROTOCOL_TREASURY` : Adresse fournie par l'opérateur pour la trésorerie du protocole.
  - `TONTINE_DEPLOYER_WALLET` : (Optionnel) Identifiant du portefeuille local Acton.
- **Mode Interactif (Terminal)** :
  En l'absence de variable d'environnement, le script interroge interactivement l'opérateur via `@acton/prompts` (`promptInt`, `promptAddress`, `promptWallet`).

---

## 3. Builder Canonique (`buildInitialTontineStorage`)

Pour éliminer toute ambiguïté de configuration, le chemin de déploiement utilise le constructeur dédié [`contracts/tontineStorage.tolk`](file:///c:/Users/DELL%20WORKSTATION/Projects/tontine-protocol-v1/contracts/tontineStorage.tolk).

### Valeurs Canoniques Fixées Immuablement :
- **Compteur Anti-Rejeu Économique** : `lastOperationQueryId = 0`.
- **Wallet Jetton du Cercle Non Résolu** : `usdtWallet = null`.
- **Drapeaux Jetton Master Config** :
  - `circleWalletLookupPending = false`
  - `circleWalletResolved = false`
  - `circleWalletQueryId = 0`
- **Machine à États** :
  - `state = 1` (`OPEN`)
  - `currentRound = 0`
  - `memberCount = 10`
  - `registeredCount = 0`
  - `fundedBondCount = 0`
  - `roundCollected = 0`
  - `protocolFeesAccrued = 0`
- **Économie V1** :
  - `contributionAmount = 20_000_000` (20 USDT)
  - `personalBond = 40_000_000` (40 USDT)
  - `protocolFeeBps = 250` (2.5% de frais de protocole)
- **Dictionnaires et Sous-États** : `members`, `rounds`, `bonds`, `contributions`, `escrow` initialisés vides ; sous-états `payout`, `settlement`, `feeState` initialisés inactifs.

### Périmètre de Garantie du Builder Canonique
`buildInitialTontineStorage` sécurise le chemin officiel de déploiement outillé. Cependant, `TontineCircle.fromStorage(...)` demeure une primitive générique fournie par le wrapper qui sérialise le storage transmis. Le bytecode de `TontineCircle` ne valide pas intrinsèquement à l'exécution que son cell initial provient de ce builder spécifique. L'invariant d'initialisation repose donc sur la rigueur du pipeline officiel de déploiement et non sur une contrainte interne au bytecode TVM.

---

## 4. Distinction Fondamentale des Domaines de Query ID

Le protocole fait intervenir deux mécanismes distincts de `queryId` qu'il convient de ne jamais confondre :

### A. Nonce Économique Global (`lastOperationQueryId`)
- Géré au niveau de `ProtocolState.lastOperationQueryId` et initialisé à `0` à l'état canonique.
- Protège strictement les opérations économiques globales contre le rejeu et la désynchronisation :
  - `PreparePayout` (préparation du paiement du tour)
  - `BeginSettlement` (règlement final d'un membre)
  - `BeginProtocolFeeWithdrawal` (retrait des frais de trésorerie)
- Pour ces opérations, le contrat impose strictement :
  $$\text{msg.queryId} == \text{lastOperationQueryId} + 1$$
- Par conséquent, la **toute première opération économique globale** exécutée sur le cercle exigera obligatoirement :
  $$\text{queryId} = 1$$

### B. Corrélation de Résolution du Circle Jetton Wallet (`circleWalletQueryId`)
- Le message `BeginCircleJettonWalletResolution` utilise son propre `queryId` pour corréler la requête `RequestWalletAddress` envoyée au Master Jetton avec la réponse `ProvideWalletAddress` reçue en retour.
- Ce `queryId` de corrélation TEP-89 **n'est pas** le nonce économique global.
- Une résolution utilisant par exemple `queryId = 10` renseigne `circleWalletQueryId = 10`, mais ne modifie aucunement `lastOperationQueryId` (qui demeure à `0`).
- Ces deux compteurs appartiennent à des espaces fonctionnels indépendants.

---

## 5. Procédure de Déploiement

### Étape 1 : Simulation en Émulation Locale
Avant toute émission sur un réseau réel, exécutez le script dans l'émulateur TVM intégré :

```bash
TONTINE_CIRCLE_ID=1 \
TONTINE_USDT_MASTER=kQD___________________________________________Bi \
TONTINE_PROTOCOL_TREASURY=kQD___________________________________________Bi \
acton script contracts/scripts/deploy.tolk
```

Le script :
1. Valide les paramètres d'entrée (`circleId` $\in [0, 2^{64}-1]$, workchains des adresses).
2. Calcule l'adresse déterministe (`StateInit`) du contrat.
3. Affiche l'adresse et les paramètres pour inspection visuelle avant émission.
4. Émule la transaction de déploiement (`0.1 TON`).
5. Interroge les getters post-déploiement pour détecter toute anomalie d'état.

### Étape 2 : Déploiement sur Réseau Testnet
Pour diffuser sur le réseau Testnet TON :

```bash
TONTINE_CIRCLE_ID=1 \
TONTINE_USDT_MASTER=<ADRESSE_USDT_MINTER_TESTNET> \
TONTINE_PROTOCOL_TREASURY=<ADRESSE_TRESORERIE_TESTNET> \
TONTINE_DEPLOYER_WALLET=my-testnet-wallet \
acton script contracts/scripts/deploy.tolk --net testnet
```

---

## 6. Vérification Post-Déploiement et Hiérarchie de Sécurité

### Nature Non-Atomique des Assertions Post-Déploiement
> [!IMPORTANT]
> Les assertions post-déploiement exécutées par le script permettent de **détecter** un état inattendu après la confirmation de la transaction. Elles **ne sont pas atomiques** avec l'envoi de la transaction broadcast.
> Si une mauvaise configuration a déjà été transmise et confirmée sur un réseau réel, une assertion échouant côté client ne peut pas annuler ou inverser la transaction on-chain.
>
> La sécurité repose donc sur la hiérarchie stricte suivante :
> 1. Utilisation exclusive du builder canonique `buildInitialTontineStorage` ;
> 2. Contrôle et validation des paramètres **avant** émission ;
> 3. Inspection attentive de l'adresse calculée et du résumé affiché dans le terminal ;
> 4. Vérification post-déploiement par getters pour confirmer l'état effectif.

### Getters Vérifiés
Après déploiement, le script interroge les getters publics suivants :

| Getter | Valeur Attendue | Signification |
| :--- | :---: | :--- |
| `lastOperationQueryId()` | `0` | Nonce économique global initial vérifié. |
| `circleJettonWalletResolved()` | `false` | Le wallet Jetton du cercle n'est pas encore résolu. |
| `circleJettonWalletLookupPending()` | `false` | Aucun lookup de wallet en suspens. |
| `state()` | `1` | Cercle en phase `OPEN` prêt à inscrire les membres. |
| `currentRound()` | `0` | Aucun tour démarré. |
| `memberCount()` | `10` | Capacité fixée à 10 membres. |
| `registeredCount()` | `0` | Aucun membre enregistré. |
| `fundedBondCount()` | `0` | Aucune caution versée. |
| `roundCollected()` | `0` | Solde collecté du tour nul. |
| `protocolFeesAccrued()` | `0` | Aucun frais accumulé. |

> [!WARNING]
> **Interdiction d'appeler `circleJettonWallet()` au déploiement** :
> Le getter `circleJettonWallet()` lève obligatoirement l'exception `CircleWalletNotResolved (1214)` tant que le wallet est `null`. L'inspection de l'état du wallet doit s'effectuer exclusivement via le booléen non bloquant `circleJettonWalletResolved()`.

---

## 7. Prochaine Étape : Résolution du Circle Jetton Wallet

Une fois le contrat déployé et vérifié, le contrôleur déclenche la résolution de son portefeuille Jetton auprès du contrat configuré comme `usdtMaster` via le message TEP-89 :

- **Opcode** : `0x52434A57` (`BeginCircleJettonWalletResolution`)
- **QueryId** : Identifiant de corrélation TEP-89 (ex: `10`, sans incidence sur `lastOperationQueryId`)
- **Émetteur** : Adresse du `controller`
- **Valeur** : `0.1` à `0.2 TON`

Le contrat émet alors une requête `RequestWalletAddress` vers `usdtMaster`, qui lui répond par `ProvideWalletAddress`, résolvant `storage.usdtWallet` relativement à l'adresse de `usdtMaster` configurée au déploiement.

---

## 8. Incompatibilité de Storage (Baseline-74)

Le layout binaire de données de cette version inclut :
1. `usdtWallet: address?` dans la cellule racine.
2. `JettonMasterConfig` enrichi (`circleWalletLookupPending`, `circleWalletResolved`, `circleWalletQueryId`).

Ce format **n'est pas rétrocompatible** avec les contrats déployés sous `baseline-74-tests`. Tout nouveau cercle doit faire l'objet d'un déploiement neuf selon le processus décrit ci-dessus.
