# Provenance des Contrats Jetton (TEP-74)

## 1. Origine Amont (Upstream Origin)
Les contrats Jetton situés dans ce répertoire (`contracts/jetton/`) proviennent du modèle officiel de référence fourni par l'outillage officiel TON **Acton** (version 1.2.0) :
- **Source** : Modèle de projet Jetton Acton (`acton new --template jetton`)
- **Version Acton utilisée** : 1.2.0
- **Exact upstream commit** : not established (sourced from Acton project template)
- **Dépôt de référence consulté** : [https://github.com/ton-blockchain/acton](https://github.com/ton-blockchain/acton)
- **Standard implémenté** : TEP-74 (Fungible tokens standard), TEP-89 (Jetton wallet discovery)
- **Licence amont** : MIT License

## 2. Inventaire des Fichiers
- `JettonMinter.tolk` : Contrat Minter de référence (émission, gestion de l'admin, calcul de l'adresse des wallets canoniques et résolution TEP-89).
- `JettonWallet.tolk` : Contrat Wallet Jetton individuel de référence (balance, transferts TEP-74, notifications de transfert, destruction/burn, gestion du stockage et gas).
- `messages.tolk` : Définitions TL-B et sérialisation des messages TEP-74 (`AskToTransfer`, `TransferNotificationForRecipient`, `InternalTransferStep`, `ReturnExcessesBack`, `MintNewJettons`, `AskToBurn`, etc.).
- `storage.tolk` : Définition des structures de stockage persistant pour le Minter (`MinterStorage`) et les Wallets (`WalletStorage`).
- `jetton-utils.tolk` : Fonctions utilitaires de calcul d'adresses déterministes StateInit des Jetton Wallets.
- `fees-management.tolk` : Calcul des réserves de stockage minimum et gestion des frais de gaz TVM pour les opérations Jetton.
- `errors.tolk` : Codes d'erreur canoniques TEP-74 (`BalanceError = 47`, `NotEnoughGas = 48`, `InvalidMessage = 49`, `NotOwner = 73`, `NotValidWallet = 74`).
- `sharding.tolk` : Primitives d'adressage et de sharding réseau.

## 3. Adaptations et Intégration au Protocole Tontine
Les modifications apportées au code source du template ont été strictement limitées aux impératifs d'intégration :
1. **Résolution des imports** : Adaptation des chemins d'importation vers `../tontineTypes`.
2. **Alignement des wrappers** : Configuration dans `Acton.toml` sous `[contracts.JettonMinter]` et `[contracts.JettonWallet]` pour la génération de wrappers typés Tolk / TypeScript.
3. **Usage dans la suite de tests** : Utilisés comme oracle et implémentation concrète de test dans `tests/JettonIntegration.test.tolk` pour émuler un USDT standard TEP-74, garantissant une intégration de bout en bout conforme au réseau TON réel (TVM emulator).
