import "@stdlib/strings"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@acton/fmt"

import "@wrappers/TontineCircle.gen"
import "@wrappers/JettonMinter.gen"
import "../contracts/tontineStorage"
import "../contracts/tontineTypes"
import "../contracts/jetton/storage"
import "../contracts/scripts/deployGuards"

fun buildTestMetadataCell(
    name: string,
    symbol: string,
    decimals: string,
    uri: string,
): cell {
    var metadata: OnchainMetadataReply = { contentDict: [] };
    metadata.contentDict.set("name".sha256(), name.prefixWith00());
    metadata.contentDict.set("symbol".sha256(), symbol.prefixWith00());
    metadata.contentDict.set("decimals".sha256(), decimals.prefixWith00());
    metadata.contentDict.set("uri".sha256(), uri.prefixWith00());
    return metadata.toCell();
}

get fun `test deterministic address calculation with explicit controller`() {
    val ctrlA = testing.treasury("readiness-ctrl-a");
    val ctrlB = testing.treasury("readiness-ctrl-b");
    val master = testing.treasury("readiness-master");
    val treasury = testing.treasury("readiness-treasury");

    val storageA1 = buildInitialTontineStorage(101, ctrlA.address, master.address, treasury.address);
    val storageA2 = buildInitialTontineStorage(101, ctrlA.address, master.address, treasury.address);

    val circleA1 = TontineCircle.fromStorage(storageA1);
    val circleA2 = TontineCircle.fromStorage(storageA2);

    // Identical parameters and controller MUST produce bit-for-bit identical StateInit and address
    expect(circleA1.address).toEqual(circleA2.address);
    expect(circleA1.stateInit!.data.hash()).toEqual(circleA2.stateInit!.data.hash());

    // A different controller MUST produce a different StateInit and address
    val storageB = buildInitialTontineStorage(101, ctrlB.address, master.address, treasury.address);
    val circleB = TontineCircle.fromStorage(storageB);
    expect(circleB.address == circleA1.address).toBeFalse();
    expect(circleB.stateInit!.data.hash() == circleA1.stateInit!.data.hash()).toBeFalse();
}

get fun `test canonical storage builder deterministically produces identical storage and StateInit across separate invocations`() {
    val ctrl = testing.treasury("readiness-ctrl-drift");
    val master = testing.treasury("readiness-master-drift");
    val treasury = testing.treasury("readiness-treasury-drift");

    // Both preflightTestnet and deploy invoke buildInitialTontineStorage directly.
    val storagePreflight = buildInitialTontineStorage(202, ctrl.address, master.address, treasury.address);
    val storageDeploy = buildInitialTontineStorage(202, ctrl.address, master.address, treasury.address);

    // Verify cell identity
    expect(storagePreflight.toCell().hash()).toEqual(storageDeploy.toCell().hash());

    // Verify all canonical economic parameters remain frozen
    expect(storagePreflight.circleId).toEqual(202);
    expect(storagePreflight.controller).toEqual(ctrl.address);
    expect(storagePreflight.state).toEqual(1);
    expect(storagePreflight.currentRound).toEqual(0);
    expect(storagePreflight.memberCount).toEqual(10);
    expect(storagePreflight.registeredCount).toEqual(0);
    expect(storagePreflight.fundedBondCount).toEqual(0);
    expect(storagePreflight.roundContributionCount).toEqual(0);
    expect(storagePreflight.roundCollected).toEqual(0);
    expect(storagePreflight.contributionAmount).toEqual(20000000);
    expect(storagePreflight.personalBond).toEqual(40000000);
    expect(storagePreflight.protocolFeeBps).toEqual(250);

    val protoState = storagePreflight.protocolState.load();
    expect(protoState.lastOperationQueryId).toEqual(0);

    val jettonCfg = protoState.jettonMasterConfig.load();
    expect(jettonCfg.usdtMaster).toEqual(master.address);
    expect(jettonCfg.protocolTreasury).toEqual(treasury.address);
    expect(jettonCfg.circleWalletResolved).toBeFalse();
    expect(jettonCfg.circleWalletLookupPending).toBeFalse();
    expect(jettonCfg.circleWalletQueryId).toEqual(0);
}

get fun `test broadcast opt-in acknowledgement helper rejects missing or invalid phrases`() {
    // Missing / null
    expect(isBroadcastOptInAcknowledged(null)).toBeFalse();

    // Empty or arbitrary values
    expect(isBroadcastOptInAcknowledged("")).toBeFalse();
    expect(isBroadcastOptInAcknowledged("true")).toBeFalse();
    expect(isBroadcastOptInAcknowledged("YES")).toBeFalse();
    expect(isBroadcastOptInAcknowledged("ALLOW_BROADCAST")).toBeFalse();
    expect(isBroadcastOptInAcknowledged("I_UNDERSTAND_THIS_IS_A_TESTNET_BROADCAST")).toBeFalse();

    // Exact required opt-in phrase
    expect(isBroadcastOptInAcknowledged("I_UNDERSTAND_THIS_IS_A_REAL_TESTNET_BROADCAST")).toBeTrue();
}

get fun `test shouldAllowBroadcast pure decision matrix`() {
    val exactAck = "I_UNDERSTAND_THIS_IS_A_REAL_TESTNET_BROADCAST";

    // In emulation mode (isBroadcasting = false), always permitted
    expect(shouldAllowBroadcast(false, null, false)).toBeTrue();
    expect(shouldAllowBroadcast(false, "wrong", false)).toBeTrue();
    expect(shouldAllowBroadcast(false, exactAck, false)).toBeTrue();

    // In broadcast mode (isBroadcasting = true):
    // 1. Missing ack, confirm false -> false
    expect(shouldAllowBroadcast(true, null, false)).toBeFalse();

    // 2. Missing ack, confirm true -> false
    expect(shouldAllowBroadcast(true, null, true)).toBeFalse();

    // 3. Wrong ack, confirm false -> false
    expect(shouldAllowBroadcast(true, "invalid", false)).toBeFalse();

    // 4. Wrong ack, confirm true -> false
    expect(shouldAllowBroadcast(true, "invalid", true)).toBeFalse();

    // 5. Valid ack, confirm false -> false (user rejected confirmation or default false)
    expect(shouldAllowBroadcast(true, exactAck, false)).toBeFalse();

    // 6. Valid ack, confirm true -> true (both barriers passed)
    expect(shouldAllowBroadcast(true, exactAck, true)).toBeTrue();
}

get fun `test parameter validation helpers enforce uint64 and valid workchains`() {
    // Circle ID: [0, 2^64-1]
    expect(validateCircleId(-1)).toBeFalse();
    expect(validateCircleId(0)).toBeTrue();
    expect(validateCircleId(1)).toBeTrue();
    expect(validateCircleId(18446744073709551615)).toBeTrue();
    expect(validateCircleId(18446744073709551616)).toBeFalse();

    // Workchains: 0 (basechain) and -1 (masterchain)
    expect(validateWorkchain(0)).toBeTrue();
    expect(validateWorkchain(-1)).toBeTrue();
    expect(validateWorkchain(1)).toBeFalse();
    expect(validateWorkchain(-2)).toBeFalse();
    expect(validateWorkchain(2)).toBeFalse();

    // Compound validation
    expect(validateDeployParameters(1, 0, 0)).toBeTrue();
    expect(validateDeployParameters(1, -1, 0)).toBeTrue();
    expect(validateDeployParameters(1, 0, -1)).toBeTrue();
    expect(validateDeployParameters(-1, 0, 0)).toBeFalse();
    expect(validateDeployParameters(1, 2, 0)).toBeFalse();
    expect(validateDeployParameters(1, 0, 2)).toBeFalse();
}

get fun `test preflight decision helper enforces NO-GO on critical failures`() {
    // 1. All critical checks pass
    val noFailures = evaluatePreflightCriticalFailures(
        true,  // circleIdValid
        true,  // controllerWcValid
        true,  // masterWcValid
        true,  // treasuryWcValid
        false, // targetAddressDeployed (clean)
        true,  // masterDeployed
        true,  // masterDataResponsive
        true,  // masterWalletResponsive
        true   // masterCodeAvailable
    );
    expect(noFailures).toEqual(0);

    // 2. Target address collision -> critical failure
    val collisionFail = evaluatePreflightCriticalFailures(
        true, true, true, true,
        true, // target already deployed!
        true, true, true, true
    );
    expect(collisionFail > 0).toBeTrue();

    // 3. Master not deployed -> critical failure
    val masterNotDeployedFail = evaluatePreflightCriticalFailures(
        true, true, true, true, false,
        false, // master not deployed!
        true, true, true
    );
    expect(masterNotDeployedFail > 0).toBeTrue();

    // 4. Master data getter unresponsive -> critical failure
    val dataGetterFail = evaluatePreflightCriticalFailures(
        true, true, true, true, false, true,
        false, // data unresponsive
        true, true
    );
    expect(dataGetterFail > 0).toBeTrue();

    // 5. Master wallet getter unresponsive -> critical failure
    val walletGetterFail = evaluatePreflightCriticalFailures(
        true, true, true, true, false, true, true,
        false, // wallet unresponsive
        true
    );
    expect(walletGetterFail > 0).toBeTrue();

    // 6. Master bytecode unavailable -> critical failure
    val codeUnavailableFail = evaluatePreflightCriticalFailures(
        true, true, true, true, false, true, true, true,
        false // bytecode unavailable
    );
    expect(codeUnavailableFail > 0).toBeTrue();
}

get fun `test preflight review status helper distinguishes NO-GO from manual review`() {
    // Critical failures = 0, warnings = 0 -> GO FOR MANUAL REVIEW
    expect(evaluatePreflightReviewStatus(0, 0)).toEqual("GO FOR MANUAL REVIEW");

    // Critical failures = 0, warnings = 1 -> GO FOR MANUAL REVIEW (operational warning does not block)
    expect(evaluatePreflightReviewStatus(0, 1)).toEqual("GO FOR MANUAL REVIEW");

    // Critical failures = 0, warnings = 5 -> GO FOR MANUAL REVIEW
    expect(evaluatePreflightReviewStatus(0, 5)).toEqual("GO FOR MANUAL REVIEW");

    // Critical failures = 1, warnings = 0 -> NO-GO
    expect(evaluatePreflightReviewStatus(1, 0)).toEqual("NO-GO");

    // Critical failures = 2, warnings = 3 -> NO-GO
    expect(evaluatePreflightReviewStatus(2, 3)).toEqual("NO-GO");
}

get fun `test expected code hash check evaluation matrix`() {
    val sampleHash = 0x123456789abcdef;
    val otherHash = 0x999999999999999;

    // 0: Unconfigured
    expect(evaluateExpectedCodeHashCheck(false, false, 0, sampleHash)).toEqual(0);
    expect(evaluateExpectedCodeHashCheck(false, true, 0, sampleHash)).toEqual(0);

    // 2: Malformed
    expect(evaluateExpectedCodeHashCheck(true, true, 0, sampleHash)).toEqual(2);

    // 1: Configured and Matching (PASS)
    expect(evaluateExpectedCodeHashCheck(true, false, sampleHash, sampleHash)).toEqual(1);

    // 3: Configured and Mismatched (FAIL)
    expect(evaluateExpectedCodeHashCheck(true, false, otherHash, sampleHash)).toEqual(3);
}

get fun `test expected code hash boundary parsing and validation`() {
    val sampleHash = 0x12345;

    // 1. Absent (null) -> manual check (0)
    val [hCfg0, hMal0, _] = parseExpectedCodeHash(null);
    expect(hCfg0).toBeFalse();
    expect(hMal0).toBeFalse();
    expect(evaluateExpectedCodeHashCheck(hCfg0, hMal0, 0, sampleHash)).toEqual(0);

    // 2. Empty string -> manual check (0)
    val [hCfgEmpty, hMalEmpty, _] = parseExpectedCodeHash("");
    expect(hCfgEmpty).toBeFalse();
    expect(hMalEmpty).toBeFalse();
    expect(evaluateExpectedCodeHashCheck(hCfgEmpty, hMalEmpty, 0, sampleHash)).toEqual(0);

    // 3. Valid decimal -> PASS parsing, match -> PASS (1), mismatch -> FAIL (3)
    val [hCfgDec, hMalDec, hValDec] = parseExpectedCodeHash("12345");
    expect(hCfgDec).toBeTrue();
    expect(hMalDec).toBeFalse();
    expect(hValDec).toEqual(12345);
    expect(evaluateExpectedCodeHashCheck(hCfgDec, hMalDec, hValDec, 12345)).toEqual(1);
    expect(evaluateExpectedCodeHashCheck(hCfgDec, hMalDec, hValDec, 99999)).toEqual(3);

    // 4. Valid hex -> PASS parsing, match -> PASS (1), mismatch -> FAIL (3)
    val [hCfgHex, hMalHex, hHexVal] = parseExpectedCodeHash("0x12345");
    expect(hCfgHex).toBeTrue();
    expect(hMalHex).toBeFalse();
    expect(hHexVal).toEqual(0x12345);
    expect(evaluateExpectedCodeHashCheck(hCfgHex, hMalHex, hHexVal, 0x12345)).toEqual(1);
    expect(evaluateExpectedCodeHashCheck(hCfgHex, hMalHex, hHexVal, 0x99999)).toEqual(3);

    // 5. "0x" alone -> malformed / FAIL (2)
    val [hCfgHexAlone, hMalHexAlone, _] = parseExpectedCodeHash("0x");
    expect(hCfgHexAlone).toBeTrue();
    expect(hMalHexAlone).toBeTrue();
    expect(evaluateExpectedCodeHashCheck(hCfgHexAlone, hMalHexAlone, 0, sampleHash)).toEqual(2);

    // 6. "0xGG" invalid hex digits -> malformed / FAIL (2)
    val [hCfgHexGG, hMalHexGG, _] = parseExpectedCodeHash("0xGG");
    expect(hCfgHexGG).toBeTrue();
    expect(hMalHexGG).toBeTrue();
    expect(evaluateExpectedCodeHashCheck(hCfgHexGG, hMalHexGG, 0, sampleHash)).toEqual(2);

    // 7. "-1" negative integer -> malformed / FAIL (2)
    val [hCfgNeg, hMalNeg, _] = parseExpectedCodeHash("-1");
    expect(hCfgNeg).toBeTrue();
    expect(hMalNeg).toBeTrue();
    expect(evaluateExpectedCodeHashCheck(hCfgNeg, hMalNeg, 0, sampleHash)).toEqual(2);

    // 8. Integer manifestly out of TVM range (100 decimal digits exceeds uint256 / 78 digits) -> malformed / FAIL (2)
    val [hCfgOverflow, hMalOverflow, _] = parseExpectedCodeHash("9999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999");
    expect(hCfgOverflow).toBeTrue();
    expect(hMalOverflow).toBeTrue();
    expect(evaluateExpectedCodeHashCheck(hCfgOverflow, hMalOverflow, 0, sampleHash)).toEqual(2);

    // 9. Arbitrary non-numeric text -> malformed / FAIL (2)
    val [hCfgBad, hMalBad, _] = parseExpectedCodeHash("not_a_valid_number");
    expect(hCfgBad).toBeTrue();
    expect(hMalBad).toBeTrue();
    expect(evaluateExpectedCodeHashCheck(hCfgBad, hMalBad, 0, sampleHash)).toEqual(2);
}

get fun `test expected admin check evaluation matrix`() {
    val adminA = testing.treasury("readiness-check-admin-a");
    val adminB = testing.treasury("readiness-check-admin-b");

    // 0: Unconfigured
    expect(evaluateExpectedAdminCheck(false, false, null, adminA.address)).toEqual(0);

    // 2: Malformed
    expect(evaluateExpectedAdminCheck(true, true, null, adminA.address)).toEqual(2);
    expect(evaluateExpectedAdminCheck(true, false, null, adminA.address)).toEqual(2);

    // 3: Onchain admin is null when expected is configured
    expect(evaluateExpectedAdminCheck(true, false, adminA.address, null)).toEqual(3);

    // 1: Configured and Matching (PASS)
    expect(evaluateExpectedAdminCheck(true, false, adminA.address, adminA.address)).toEqual(1);

    // 3: Configured and Mismatched (FAIL)
    expect(evaluateExpectedAdminCheck(true, false, adminA.address, adminB.address)).toEqual(3);
}

get fun `test expected admin address boundary parsing and validation`() {
    // 1. Absent (null) -> manual check (0)
    val [aCfg0, aMal0, _] = parseExpectedAdminAddress(null);
    expect(aCfg0).toBeFalse();
    expect(aMal0).toBeFalse();

    // 2. Empty string -> manual check (0)
    val [aCfgEmpty, aMalEmpty, _] = parseExpectedAdminAddress("");
    expect(aCfgEmpty).toBeFalse();
    expect(aMalEmpty).toBeFalse();

    // 3. Arbitrary malformed string -> malformed / FAIL (2)
    val [aCfgBad, aMalBad, _] = parseExpectedAdminAddress("invalid_address_syntax");
    expect(aCfgBad).toBeTrue();
    expect(aMalBad).toBeTrue();
    expect(evaluateExpectedAdminCheck(aCfgBad, aMalBad, null, null)).toEqual(2);

    // 4. Valid length (48) but invalid checksum -> FAIL (2)
    val [aCfgBadChk, aMalBadChk, _] = parseExpectedAdminAddress("kQCPFJYFqhowz0BRAfqNPdLOC1_Rlupki_0BezWU6rHk5lbX");
    expect(aCfgBadChk).toBeTrue();
    expect(aMalBadChk).toBeTrue();
    expect(evaluateExpectedAdminCheck(aCfgBadChk, aMalBadChk, null, null)).toEqual(2);

    // 5. Valid length (48) but invalid characters ('?') -> FAIL (2)
    val [aCfgBadChar, aMalBadChar, _] = parseExpectedAdminAddress("kQCPFJYFqhowz0BRAfqNPdLOC1_Rlupki_0BezWU6rHk5lb?");
    expect(aCfgBadChar).toBeTrue();
    expect(aMalBadChar).toBeTrue();
    expect(evaluateExpectedAdminCheck(aCfgBadChar, aMalBadChar, null, null)).toEqual(2);

    // 6. Valid user-friendly address -> accepted, match -> PASS (1)
    val validFriendly = "kQCPFJYFqhowz0BRAfqNPdLOC1_Rlupki_0BezWU6rHk5lbt";
    val [aCfgFriendly, aMalFriendly, aAddrFriendly] = parseExpectedAdminAddress(validFriendly);
    expect(aCfgFriendly).toBeTrue();
    expect(aMalFriendly).toBeFalse();
    expect(aAddrFriendly!).toEqual(parseAddress(validFriendly));
    expect(evaluateExpectedAdminCheck(aCfgFriendly, aMalFriendly, aAddrFriendly, aAddrFriendly)).toEqual(1);

    // 7. Valid raw address: 0: + 64 hex -> accepted, match -> PASS (1)
    val rawBase = "0:0000000000000000000000000000000000000000000000000000000000000001";
    val [aCfgRaw0, aMalRaw0, aAddrRaw0] = parseExpectedAdminAddress(rawBase);
    expect(aCfgRaw0).toBeTrue();
    expect(aMalRaw0).toBeFalse();
    expect(aAddrRaw0!).toEqual(parseAddress(rawBase));
    expect(evaluateExpectedAdminCheck(aCfgRaw0, aMalRaw0, aAddrRaw0, aAddrRaw0)).toEqual(1);

    // 8. Valid raw address: -1: + 64 hex -> accepted, match -> PASS (1)
    val rawMaster = "-1:0000000000000000000000000000000000000000000000000000000000000001";
    val [aCfgRawM, aMalRawM, aAddrRawM] = parseExpectedAdminAddress(rawMaster);
    expect(aCfgRawM).toBeTrue();
    expect(aMalRawM).toBeFalse();
    expect(aAddrRawM!).toEqual(parseAddress(rawMaster));
    expect(evaluateExpectedAdminCheck(aCfgRawM, aMalRawM, aAddrRawM, aAddrRawM)).toEqual(1);

    // 9. Mismatch check between two valid addresses -> FAIL (3)
    expect(evaluateExpectedAdminCheck(aCfgRaw0, aMalRaw0, aAddrRaw0, aAddrRawM)).toEqual(3);

    // 10. Expected configured + on-chain admin null -> FAIL (3)
    expect(evaluateExpectedAdminCheck(aCfgFriendly, aMalFriendly, aAddrFriendly, null)).toEqual(3);
}

get fun `test mint validation helpers enforce positive amount, workchains, and admin matching`() {
    // Amount validation: strictly positive, <= MAX_COINS (2^120 - 1)
    expect(validateMintAmount(0)).toBeFalse();
    expect(validateMintAmount(-1)).toBeFalse();
    expect(validateMintAmount(-100)).toBeFalse();
    expect(validateMintAmount(1)).toBeTrue();
    expect(validateMintAmount(100000000)).toBeTrue();
    expect(validateMintAmount(1329227995784915872903807060280344575)).toBeTrue();
    expect(validateMintAmount(MAX_COINS)).toBeTrue();

    // Exact VarUInteger16 overflow bound: 2^120 MUST be rejected
    expect(validateMintAmount(1329227995784915872903807060280344576)).toBeFalse();
    expect(validateMintAmount(MAX_COINS + 1)).toBeFalse();

    // Admin matching
    val adminA = testing.treasury("mint-admin-a");
    val adminB = testing.treasury("mint-admin-b");
    expect(isMinterAdminMatching(adminA.address, adminA.address)).toBeTrue();
    expect(isMinterAdminMatching(adminA.address, adminB.address)).toBeFalse();
    expect(isMinterAdminMatching(null, adminA.address)).toBeFalse();
}

get fun `test cumulative supply overflow prevention helper`() {
    // 0 + MAX_COINS = MAX_COINS <= MAX_COINS -> true
    expect(canMintWithoutSupplyOverflow(0, MAX_COINS)).toBeTrue();

    // (MAX_COINS - 1) + 1 = MAX_COINS <= MAX_COINS -> true
    expect(canMintWithoutSupplyOverflow(MAX_COINS - 1, 1)).toBeTrue();

    // MAX_COINS + 1 -> false (overflow beyond 2^120 - 1)
    expect(canMintWithoutSupplyOverflow(MAX_COINS, 1)).toBeFalse();

    // (MAX_COINS - 1) + 2 -> false (overflow beyond 2^120 - 1)
    expect(canMintWithoutSupplyOverflow(MAX_COINS - 1, 2)).toBeFalse();

    // Standard realistic mint: 100 + 100 -> true
    expect(canMintWithoutSupplyOverflow(100, 100)).toBeTrue();

    // Negative initialSupply -> false
    expect(canMintWithoutSupplyOverflow(-1, 1)).toBeFalse();

    // Negative or zero amount -> false
    expect(canMintWithoutSupplyOverflow(0, -1)).toBeFalse();
    expect(canMintWithoutSupplyOverflow(0, 0)).toBeFalse();

    // initialSupply already exceeding MAX_COINS -> false
    expect(canMintWithoutSupplyOverflow(MAX_COINS + 1, 1)).toBeFalse();
}

get fun `test testnet jetton metadata encoding and display convention`() {
    val admin = testing.treasury("readiness-jetton-admin");
    val metadata = buildTestMetadataCell(
        "Tontine Test Jetton",
        "USDTT",
        "6",
        "https://tontine.finance/usdtt.json",
    );

    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: admin.address,
        metadata,
        nextAdminAddress: null,
    });

    val deployRes = minter.deploy(admin.address, { value: grams("1") });
    expect(deployRes).toHaveSuccessfulDeploy({ to: minter.address });

    // Verify getters
    val data = minter.getJettonData();
    expect(data.totalSupply).toEqual(0);
    expect(data.mintable).toBeTrue();
    expect(data.adminAddress).toEqual(admin.address);

    // Verify metadata content cell decoding: unpack and check exact values
    val onchainMeta = data.jettonContent.load();
    val decLookup = onchainMeta.contentDict.get("decimals".sha256());
    expect(decLookup.isFound).toBeTrue();
    expect(decLookup.loadValue()).toEqual("6".prefixWith00());

    val symLookup = onchainMeta.contentDict.get("symbol".sha256());
    expect(symLookup.isFound).toBeTrue();
    expect(symLookup.loadValue()).toEqual("USDTT".prefixWith00());

    val nameLookup = onchainMeta.contentDict.get("name".sha256());
    expect(nameLookup.isFound).toBeTrue();
    expect(nameLookup.loadValue()).toEqual("Tontine Test Jetton".prefixWith00());

    // Verify wallet address derivation
    val user = testing.treasury("readiness-jetton-user");
    val walletAddr = minter.getWalletAddress(user.address);
    expect(walletAddr.getWorkchain()).toEqual(0);
}

get fun `test jetton supply verification increases strictly by minted amount`() {
    val admin = testing.treasury("mint-verify-admin");
    val recipient = testing.treasury("mint-verify-user");

    val minter = JettonMinter.fromStorage({
        totalSupply: 0,
        adminAddress: admin.address,
        metadata: buildTestMetadataCell("Tontine Test Jetton", "USDTT", "6", "https://tontine.finance/usdtt.json"),
        nextAdminAddress: null,
    });
    val deployRes = minter.deploy(admin.address, { value: grams("1") });
    expect(deployRes).toHaveSuccessfulDeploy({ to: minter.address });

    val initialSupply = minter.getJettonData().totalSupply;
    expect(initialSupply).toEqual(0);

    // Execute mint of 100_000_000 microunits (100 USDTT)
    val mintAmount: coins = 100000000;
    val internalMsg = beginCell()
        .storeUint(0x178d4519, 32)
        .storeUint(1, 64)
        .storeCoins(mintAmount)
        .storeAddress(admin.address)
        .storeAddress(admin.address)
        .storeCoins(0)
        .storeUint(0, 1)
        .endCell();

    val mintMsg = beginCell()
        .storeUint(0x642b7d07, 32)
        .storeUint(1, 64)
        .storeAddress(recipient.address)
        .storeCoins(grams("0.2"))
        .storeRef(internalMsg)
        .endCell();

    minter.sendAny(admin.address, mintMsg, { value: grams("0.5") });

    // Objective verification: post-mint totalSupply strictly equals initial + mintAmount
    val postSupply = minter.getJettonData().totalSupply;
    expect(postSupply).toEqual(initialSupply + mintAmount);
}
