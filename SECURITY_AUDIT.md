# RAPPORT D'AUDIT DE SÉCURITÉ APPROFONDI & DURCISSEMENT — PROTOCOLE TONTINE V1 (TON / TOLK)

**Date** : 27 Septembre 2026
**Lead Developer & Security Engineering** : Antigravity
**Projet** : `tontine-protocol-v1`
**Environnement de référence** : Acton v1.2.0 (Tolk Smart Contract Language, TVM Emulator)
**Baseline Git immuable** : commit `3cc7643` (tag `baseline-74-tests`)
**Résultats des tests** : **107 tests passés / 107 (100% SUCCÈS)**
- 97 tests unitaires et de sécurité dans `tests/TontineCircle.test.tolk`
- 6 tests d'intégration avec contrats Jetton réels dans `tests/JettonIntegration.test.tolk`
- 4 tests de base de contrat dans `contracts/tests/contract.test.tolk`

---

## 1. Résumé Exécutif

À la suite de l'audit initial (portant la couverture à 74 tests) et d'un contre-audit indépendant, un programme complet de durcissement technique a été réalisé sur le contrat `TontineCircle.tolk` et sa suite de tests. La suite passe désormais avec succès **107 tests sur 107**.

### Synthèse des Chantiers Réalisés :
1. **Anti-Rejeu Strict Séquentiel (Chantier 1)** : Contrainte stricte `msg.queryId == lastOperationQueryId + 1` sur chaque opération modifiant l'état global (`PreparePayout`, `BeginSettlement`, `BeginProtocolFeeWithdrawal`), avec garde défensive contre le débordement à $2^{64}-1$ (`QueryIdOverflow = 1501`). Les étapes intermédiaires (résolution de wallet, dispatches) préservent le `queryId` sans faire progresser le compteur global.
2. **Résolution Canonique du Circle Jetton Wallet (Chantier 2)** : Suppression de l'injection arbitraire `SetCircleJettonWallet`. Résolution canonique one-shot via `BeginCircleJettonWalletResolution` (op `0x52434A57`) auprès du contrat minter officiel `usdtMaster` (standard TEP-89), avec authentification de l'expéditeur (`in.senderAddress == config.usdtMaster`) et vérification d'identité (`ownerAddress == contract.getAddress()`). Les dépôts (cautions, cotisations) et dispatches sont conditionnés par `circleWalletResolved`.
3. **Durcissement des Bounces TVM (Chantier 3)** : Authentification préalable de l'expéditeur du rebond (seuls `usdtWallet` et `usdtMaster` sont autorisés). Bornage de taille minimale (100 bits pour `AskToTransfer`, 96 bits pour `RequestWalletAddress`), validation TL-B de longueur `VarUInteger 16`. Gestion défensive des rebonds TVM 256 bits (`0xffffffff`) et prise en charge synthétique du préfixe TVM 12 `RichBounceBody` (`0xfffffffe`) avec vérification des références (`remainingRefsCount() >= 1`). Réinitialisation de l'état lors d'un rebond sur le retrait des frais de protocole.
4. **Test de Bounce Réel sur Émulateur TVM (Chantier 4)** : Émulation d'une erreur de solde réelle (`Errors.BalanceError = 47`) sur un portefeuille Jetton réel déployé sur la TVM, provoquant un rebond TVM authentique vers `TontineCircle` et réinitialisant `payoutDispatched = false`.
5. **Intégration Jetton Entrante E2E (Chantier 5)** : Flux complet d'exécution `JettonWallet.sendTransfer` (AskToTransfer) $\to$ `circleWallet` (InternalTransferStep) $\to$ `TontineCircle` (TransferNotificationForRecipient), validant la mise à jour des positions de membre (caution et cotisation) à partir de transferts Jetton réels.
6. **Vérification de Solvabilité sur Solde Jetton Réel (Chantier 6)** : Concordance comptable stricte entre la somme dynamique des passifs calculée via les getters du contrat ($\sum \text{bondLocked} + \sum \text{escrowLocked} + \text{protocolFeesAccrued} = 1010$ USDT) et le solde effectif `circleWallet.getWalletData().jettonBalance` au terme des 10 tours.
7. **Documentation de Provenance des Contrats Jetton (Chantier 7)** : Rédaction de `contracts/jetton/UPSTREAM.md` documentant la source Acton v1.2.0, les interfaces TEP-74/89 et les adaptations effectuées.
8. **Modèle Économique & Bilan Financier (Chantier 8)** : Formulation exacte du séquestre et publication du bilan financier détaillé.

---

## 2. Modèle Économique & Formules Mathématiques Exactes

Le contrat `TontineCircle` régit une association rotative d'épargne et de crédit (tontine financière) à 10 participants opérant en USDT (Jetton TEP-74, 6 décimales) :

- **Membres** : Exactement 10 participants (`memberCount = 10`), assignés aux tours 1 à 10.
- **Caution personnelle (Personal Bond)** : 40 USDT par membre déposés en phase `OPEN`, soit 400 USDT immobilisés au total.
- **Cotisation par tour** : 20 USDT par membre par tour actif.
- **Collecte brute par tour** : $10 \times 20 = 200$ USDT (`roundCollected`).
- **Frais de protocole par tour** : $2.5\%$ du pot brut = 5 USDT prélevés à chaque tour (`roundCollected * protocolFeeBps / 10000`).

### Formule Canonique du Séquestre (Escrow)
À chaque tour $R \in [1, 10]$, la dette future du bénéficiaire s'élève à :
$$\text{remainingDebt}(R) = (10 - R) \times 20\text{ USDT}$$

Le protocole couvre cette dette prioritairement par les garanties hors-séquestre, constituées de la caution déjà consignée et de $50\%$ des garanties actives reconnues (P2P et protocole) :
$$\text{coverageOutsideEscrow} = \text{bondLocked} + \frac{\text{p2pGuaranteeActive} + \text{protocolGuaranteeActive}}{2}$$

En l'absence de garanties additionnelles ($\text{garanties} = 0$), la retenue de séquestre sur le pot du tour est strictement :
$$\text{Escrow}(R) = \max\Big(0,\; \text{remainingDebt}(R) - \text{bondLocked}\Big) = \max\Big(0,\; (10 - R) \times 20 - 40\Big)$$

Le montant décaissé net au bénéficiaire du tour est :
$$\text{NetPayout}(R) = \text{roundCollected} - \text{Escrow}(R) - \text{ProtocolFee}(R) = 200 - \text{Escrow}(R) - 5$$

### Tableau Bilan des 10 Tours
| Tour ($R$) | Bénéficiaire | Dette Restante | Caution | Séquestre Retenu | Frais Protocole | Paiement Net |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **1** | Membre 1 | 180 USDT | 40 USDT | **140 USDT** | 5 USDT | **55 USDT** |
| **2** | Membre 2 | 160 USDT | 40 USDT | **120 USDT** | 5 USDT | **75 USDT** |
| **3** | Membre 3 | 140 USDT | 40 USDT | **100 USDT** | 5 USDT | **95 USDT** |
| **4** | Membre 4 | 120 USDT | 40 USDT | **80 USDT** | 5 USDT | **115 USDT** |
| **5** | Membre 5 | 100 USDT | 40 USDT | **60 USDT** | 5 USDT | **135 USDT** |
| **6** | Membre 6 | 80 USDT | 40 USDT | **40 USDT** | 5 USDT | **155 USDT** |
| **7** | Membre 7 | 60 USDT | 40 USDT | **20 USDT** | 5 USDT | **175 USDT** |
| **8** | Membre 8 | 40 USDT | 40 USDT | **0 USDT** | 5 USDT | **195 USDT** |
| **9** | Membre 9 | 20 USDT | 40 USDT | **0 USDT** | 5 USDT | **195 USDT** |
| **10** | Membre 10 | 0 USDT | 40 USDT | **0 USDT** | 5 USDT | **195 USDT** |
| **TOTAL** | — | — | — | **560 USDT** | **50 USDT** | **1390 USDT** |

### Bilan Comptable
1. **Entrées prévues du cycle complet** :
   - 10 Cautions de 40 USDT = 400 USDT
   - 10 Tours $\times$ 10 Cotisations de 20 USDT = 2000 USDT
   - **Total collecté** = $400 + 2000 = 2400$ USDT
2. **Sorties de paiements (Payouts)** :
   - Somme des décaissements nets des tours 1 à 10 = **1390 USDT**
3. **Actifs résiduels en coffre** :
   $$\text{Solde Jetton restant} = 2400 - 1390 = \mathbf{1010\text{ USDT}}$$
4. **Passifs exigibles au règlement (Settlement)** :
   - Cautions restituables : $10 \times 40 = 400$ USDT
   - Séquestres restituables : 560 USDT
   - Total passif envers les membres : $400 + 560 = 960$ USDT
   - Frais de protocole accumulés (pour la trésorerie) : 50 USDT
   - **Total passif global** = $960 + 50 = \mathbf{1010\text{ USDT}}$

L'égalité $\text{Actifs en coffre} \equiv \text{Passifs exigibles} = 1010$ USDT est vérifiée unitairement et en test d'intégration sur émulateur TVM.

---

## 3. Détail des Correctifs Techniques de Sécurité

### 1. Anti-Rejeu Strict Séquentiel (`msg.queryId`)
- Chaque initiation majeure (`PreparePayout`, `BeginSettlement`, `BeginProtocolFeeWithdrawal`) applique les vérifications :
  ```tolk
  assert (protocolState.lastOperationQueryId < 18446744073709551615)
      throw TontineErrors.QueryIdOverflow;

  assert (msg.queryId == protocolState.lastOperationQueryId + 1)
      throw TontineErrors.ReplayedQueryId;
  ```
- Les opérations de retry et de dispatch (`ResolvePayoutWallet`, `DispatchPayout`, `RetrySettlementWallet`, `DispatchSettlement`, etc.) exigent strictement l'égalité avec le `queryId` de l'opération en cours sans avancer le compteur global.
- **Analyse du cycle de vie du nonce** : Un cycle complet de tontine comporte exactement 21 opérations modifiant `lastOperationQueryId` (10 `PreparePayout` + 10 `BeginSettlement` + 1 `BeginProtocolFeeWithdrawal`). La valeur maximale $2^{64}-1 \approx 1.84 \times 10^{19}$ est mathématiquement inaccessible dans des conditions normales. Le contrôle de débordement constitue une mesure de sécurité défensive.

### 2. Résolution du Wallet Jetton du Cercle
- Suppression de l'affectation manuelle par le contrôleur.
- Résolution standard TEP-89 vers `usdtMaster` :
  ```tolk
  val lookupMsg = createMessage({
      bounce: BounceMode.Only256BitsOfBody,
      value: grams("0.05"),
      dest: config.usdtMaster,
      body: RequestWalletAddress {
          queryId: msg.queryId,
          ownerAddress: contract.getAddress(),
          includeOwnerAddress: true,
      },
  });
  ```
- Réception et authentification :
  ```tolk
  assert (in.senderAddress == config.usdtMaster)
      throw TontineErrors.UnauthorizedJettonWallet;

  if (!config.circleWalletResolved && config.circleWalletLookupPending) {
      assert (msg.queryId == config.circleWalletQueryId)
          throw TontineErrors.CircleWalletQueryMismatch;

      assert (msg.ownerAddress != null)
          throw TontineErrors.JettonWalletOwnerMismatch;

      assert (msg.ownerAddress!.load() == contract.getAddress())
          throw TontineErrors.JettonWalletOwnerMismatch;

      assert (msg.jettonWalletAddress != null)
          throw TontineErrors.WalletNotResolved;

      storage.usdtWallet = msg.jettonWalletAddress;
      config.circleWalletResolved = true;
      config.circleWalletLookupPending = false;
      ...
  }
  ```
- L'opération `BeginCircleJettonWalletResolution` est réservée au contrôleur et n'est autorisée qu'en phase `OPEN` (`state == 1`) tant qu'aucun dépôt de caution n'a été enregistré (`fundedBondCount == 0`).
- Les notifications de transfert et les fonctions de dispatch vérifient `config.circleWalletResolved` et `storage.usdtWallet != null`.

### 3. Durcissement Résilient des Bounces TVM
- Le protocole utilise exclusivement `BounceMode.Only256BitsOfBody` sur ses messages sortants et n'émet pas de messages au format `RichBounce`.
- Dans `onBouncedMessage`, l'authentification de l'expéditeur est effectuée avant tout décodage :
  ```tolk
  val isCircleWallet = (storage.usdtWallet != null && in.senderAddress == storage.usdtWallet!);
  val isMaster = (in.senderAddress == config.usdtMaster);
  if (!isCircleWallet && !isMaster) {
      return;
  }
  ```
- Bornages de sécurité et vérification de structure :
  - Rejet si la taille est inférieure à 32 bits.
  - Rejet sur `AskToTransfer` si la taille est inférieure à 100 bits (op 32 bits + queryId 64 bits + préfixe de longueur VarUInteger 16 de 4 bits).
  - Validation du format TL-B de `VarUInteger 16` (`neededCoinsBits = 4 + coinsByteLen * 8`).
  - Rejet sur `RequestWalletAddress` si la taille est inférieure à 96 bits (op 32 bits + queryId 64 bits).
- Support défensif synthétique pour TVM 12 :
  - Préfixe standard TVM 256 bits (`0xffffffff`) : `bounceBody.skipBouncedPrefix()`.
  - Préfixe TVM 12 `RichBounceBody` (`0xfffffffe`) : vérification préalable `if (bounceBody.remainingRefsCount() < 1) { return; }` avant accès à `RichBounceBody.fromSlice(bounceBody)`.
- Prise en charge du rebond lors du retrait des frais de protocole (`withdrawalDispatched = false`).

---

## 4. Compatibilité de Storage (Storage Compatibility)

> [!WARNING]
> Les modifications structurelles introduites dans ce durcissement rompent la compatibilité binaire avec le layout de stockage de `baseline-74-tests`.

### Ruptures de Layout Identifiées :
1. **Ajout de `usdtWallet: address?`** dans la cellule racine de `TontineStorage`.
2. **Enrichissement de `JettonMasterConfig`** avec les champs :
   - `circleWalletLookupPending: bool`
   - `circleWalletResolved: bool`
   - `circleWalletQueryId: uint64`

### Conséquences Opérationnelles :
- **Déploiement frais requis** : Ce contrat ne peut pas être déployé comme une mise à jour (code upgrade) sur un contrat existant déployé sous `baseline-74-tests`. La tentative de désérialisation du storage échouerait avec une exception de désérialisation / Cell Underflow.
- **Évolutions futures** : Toute mise à niveau on-chain ultérieure nécessitera soit un contrat proxy de migration, soit un versioning explicite du schéma de stockage (ex: tag de version dans la cellule racine).

---

## 5. Couverture des Tests et Validation

### Bilan Global des Tests
| Fichier de Test | Nombre de Tests | Résultat |
| :--- | :---: | :---: |
| `contracts/tests/contract.test.tolk` | **4** | **100% SUCCÈS** |
| `tests/JettonIntegration.test.tolk` | **6** | **100% SUCCÈS** |
| `tests/TontineCircle.test.tolk` | **97** | **100% SUCCÈS** |
| **TOTAL** | **107** | **100% SUCCÈS** |

### Détail des Tests d'Intégration (`JettonIntegration.test.tolk`)
1. `integration: minter deploys and calculates wallet addresses` : Déploiement du minter de référence et calcul StateInit d'adresses de portefeuille Jetton.
2. `integration: circle resolves beneficiary wallet through real JettonMinter` : Résolution asynchrone réelle via `RequestWalletAddress` / `ResponseWalletAddress` entre contrats.
3. `integration: full payout dispatch and excess return with real Jetton contracts` : Chaîne complète de décaissement de tour (`circle` $\to$ `circleWallet` $\to$ `beneficiaryWallet` $\to$ notification d'excès vers `circle`).
4. `integration: genuine TVM emulator bounce on real JettonWallet balance error resets payout dispatch` : Erreur de balance réelle `Errors.BalanceError (47)` sur TVM, émission d'un bounce TVM authentique et réinitialisation de `payoutDispatched = false`.
5. `integration: e2e inbound jetton transfer for bond funding and round contribution` : Dépôt entrant réel par un membre via son propre JettonWallet (`AskToTransfer` $\to$ `InternalTransferStep` $\to$ `TransferNotificationForRecipient`) validant la caution (40 USDT) et la cotisation (20 USDT).
6. `integration: prefunded real jetton balance matches liabilities after ten real payouts` : Déroulement complet des 10 tours avec un pool pré-financé de 2400 USDT sur `circleWallet`, 10 transferts réels de paiement, et confirmation de l'égalité stricte entre passifs exigibles (960 USDT membres + 50 USDT frais = 1010 USDT) et solde Jetton résiduel (1010 USDT). (Les cotisations intermédiaires sont émises par notification depuis `circleWallet`, le flux de dépôt individuel complet étant couvert par le test E2E dédié).

---

## 6. Wrapper et Génération de Code

L'outillage Acton génère le wrapper `TontineCircle.gen.tolk` sur la base de la déclaration `incomingMessages` du contrat :
```tolk
type AllowedMessage = AddMember;

contract TontineCircle {
    ...
    incomingMessages: AllowedMessage
}
```
Seule la fonction typée `sendAddMember` ainsi que la fonction générique `sendAny` sont produites par le générateur. Les messages internes d'orchestration (`BeginCircleJettonWalletResolution`, `PreparePayout`, `DispatchPayout`, `BeginSettlement`, `DispatchSettlement`, `BeginProtocolFeeWithdrawal`, `DispatchProtocolFeeWithdrawal`) sont transmis via `contract.sendAny(...)` avec sérialisation de la cellule correspondante. Cette approche respecte le modèle standard Acton sans introduire d'abstraction artificielle.

---

## 7. Recommandations Pré-Mainnet & Risques Résiduels

1. **Gouvernance Multi-Sig** : Le contrôleur (`controller`) détient des prérogatives d'orchestration (ajout de membres, verrouillage, préparation des paiements). Une transition vers un contrat Multi-Sig (ex: Ton-Multisig v2) est recommandée pour les cercles à enjeux financiers élevés.
2. **Audit Externe Indépendant** : Un audit par une firme tierce spécialisée en sécurité TVM reste impératif avant tout déploiement en production avec des fonds utilisateurs réels.
3. **Approvisionnement en Gas TON** : Les transactions d'orchestration multi-sauts doivent être pourvues d'au moins 0.2 à 0.5 TON pour couvrir sans défaillance les cascades de messages inter-contrats.
4. **Déploiement Initial** : Le protocole nécessite un déploiement neuf en raison de la rupture de compatibilité de stockage avec la baseline.
