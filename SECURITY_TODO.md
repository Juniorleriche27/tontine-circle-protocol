# ROADMAP DE SÉCURITÉ & PROBLÈMES OUVERTS (V2) — PROTOCOLE TONTINE

Ce document consigne de manière exhaustive les améliorations architecturales, les chantiers de décentralisation et les problématiques ouvertes non résolues dans la version V1 du protocole `tontine-protocol-v1`.

---

## 1. Réconciliation On-Chain Décentralisée de l'État "Stale Dispatch"

### Problème Identifié en V1
Lorsqu'un dispatch de paiement (`payoutDispatched`), de règlement (`settlementDispatched`) ou de frais de protocole (`withdrawalDispatched`) reste en suspens sans réception du message `ReturnExcessesBack` (par exemple en raison d'un épuisement de gas sur le jetton wallet ou d'un retard de routage inter-shard) :
- En V1, le protocole **interdit** tout retry automatique pour éliminer mathématiquement le risque de double-paiement.
- Cependant, en l'absence de bounce explicite et sans accusé de réception d'excès, l'opération reste verrouillée dans l'état `dispatched = true`.

### Solution Architecturale V2 Requise
Mettre en place un mécanisme de réconciliation on-chain formel permettant de prouver sans ambiguïté l'état du transfert :
1. **Requête d'Attestation de Balance / Nonce auprès du Jetton Wallet** :
   Définir un protocole d'interrogation cryptographique permettant au cercle de demander au `JettonWallet` officiel son solde ou son nonce de transaction avec preuve Merkle TVM.
2. **Consensus Multi-Partie / Signature de Témoins** :
   En cas de timeout certifié ($T_{\text{now}} > T_{\text{dispatched}} + \Delta_{\text{timeout}}$), permettre à un quorum de participants ou d'oracles signataires de soumettre une preuve cryptographique de non-encaissement, déverrouillant le dispatch de manière trust-minimized.

---

## 2. Décentralisation de la Gouvernance & Multi-Sig

### État Actuel (V1)
Le rôle `controller` est assigné à une adresse unique. Bien que ses actions soient strictement bornées par la machine à états (impossibilité de dévier des montants pré-calculés, impossibilité de modifier les tours une fois verrouillés), la défaillance ou la compromission de la clé du contrôleur peut bloquer l'orchestration du cercle.

### Évolution V2
- Remplacer le `controller` mono-adresse par une intégration native d'un contrat Multi-Sig (ex: standard Ton-Multisig v2) ou par une gouvernance autonome basée sur les signatures des membres du cercle eux-mêmes.
- Permettre aux membres de déclencher eux-mêmes les transitions de tour par consensus lorsque le contrôleur devient inactif pendant plus d'une période définie.

---

## 3. Gestion Avancée du Solde TON et des Réservations de Gas

### État Actuel (V1)
Le contrat conserve les TON nécessaires à son stockage et à l'expédition des messages grâce à la gestion standard des valeurs de message. Si un appelant n'envoie pas suffisamment de TON pour couvrir les frais de forwarding et de gaz, la transaction peut échouer sans rebond complet.

### Évolution V2
- Implémenter une formule explicite de `reserveGramsOnBalance` calculant dynamiquement les coûts de stockage pour la durée prévisionnelle de la tontine (ex: 10 mois) au moment du `LOCK`.
- Intégrer un mécanisme de restitution automatique du surplus de TON (carry remaining gas) systématique vers l'expéditeur d'origine.

---

## 4. Scaling Dynamique et Pagination des Membres

### État Actuel (V1)
Le contrat est calibré pour un nombre fixe de 10 membres avec un mapping interne `map<address, MemberPosition>`. Cette configuration est optimale en termes de gas et de complexité pour un cercle standard.

### Évolution V2
Pour supporter des cercles de plus grande envergure (ex: 50 à 100 membres) :
- Adopter un schéma de sharding ou de sous-contrats de membres (SBT / NFT de position) pour éviter de dépasser les limites de profondeur et de gas de cell de la TVM lors de l'itération complète des règlements.
- Mettre en place un système de pagination asynchrone pour la déclaration des défauts et le calcul des garanties P2P.

---

## 5. Support de Collatéraux Asymétriques & Yield-Bearing Assets

### État Actuel (V1)
Le protocole utilise exclusivement des montants fixes en USDT (unités de 6 décimales).

### Évolution V2
- Supporter des tokens à rendement (ex: tsTON, stTON ou USDT déposés dans un vault de prêt type EVAA) permettant aux cautions immobilisées de générer des intérêts au bénéfice des participants pendant la durée du cycle.
- Intégrer un oracle de prix DEX (ex: DeDust / STON.fi) si des cautions multi-devises sont acceptées.

---

## 6. Audit Externe Formel & Fuzzing TVM Continu

### Actions Requises avant Déploiement Mainnet
1. **Audit Externe Indépendant** : Soumettre le présent audit et le code corrigé à une firme de sécurité spécialisée dans l'écosystème TON (ex: CertiK, Cyberscope, Trail of Bits).
2. **Campagne de Fuzzing TVM** : Mettre en œuvre un harnais de fuzzing automatisé (ex: `acton` fuzzing ou générateur de traces aléatoires) pour tester des milliards de combinaisons d'ordres d'arrivée de messages, de gas limites aléatoires et de simulations de congestion réseau extrême.
