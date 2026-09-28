import "@stdlib/strings"
import "@acton/prompts"
import "@acton/ffi"
import "@acton/fmt"

/// Exact upper bound for TON VarUInteger16 / coins: 2^120 - 1
const MAX_COINS: int = 1329227995784915872903807060280344575;

const BROADCAST_OPT_IN_ACK_VALUE: string = "I_UNDERSTAND_THIS_IS_A_REAL_TESTNET_BROADCAST";
const PREFLIGHT_MIN_CONTROLLER_BALANCE: int = 200000000; // 0.2 TON operational threshold

/// Validates that circleId is an unsigned 64-bit integer [0, 2^64-1]
fun validateCircleId(circleId: int): bool {
    return circleId >= 0 && circleId <= 18446744073709551615;
}

/// Validates that an address belongs to basechain (0) or masterchain (-1)
fun validateWorkchain(workchain: int): bool {
    return workchain == 0 || workchain == -1;
}

/// Validates all parameters required for canonical deployment
fun validateDeployParameters(circleId: int, masterWc: int, treasuryWc: int): bool {
    return validateCircleId(circleId) && validateWorkchain(masterWc) && validateWorkchain(treasuryWc);
}

/// Validates that the operator provided the exact broadcast opt-in acknowledgement phrase
fun isBroadcastOptInAcknowledged(authEnvValue: string?): bool {
    if (authEnvValue == null) {
        return false;
    }
    return authEnvValue!.equalTo(BROADCAST_OPT_IN_ACK_VALUE);
}

/// Evaluates whether a deployment execution should proceed given broadcasting and confirmation status
fun shouldAllowBroadcast(
    isBroadcasting: bool,
    authEnvValue: string?,
    userConfirmed: bool,
): bool {
    if (!isBroadcasting) {
        // Local emulation mode is always permitted
        return true;
    }
    // Real broadcast strictly requires both explicit acknowledgement phrase AND user confirmation
    return isBroadcastOptInAcknowledged(authEnvValue) && userConfirmed;
}

/// Evaluates preflight critical checks and returns count of critical failures
fun evaluatePreflightCriticalFailures(
    circleIdValid: bool,
    controllerWcValid: bool,
    masterWcValid: bool,
    treasuryWcValid: bool,
    targetAddressDeployed: bool,
    masterDeployed: bool,
    masterDataResponsive: bool,
    masterWalletResponsive: bool,
    masterCodeAvailable: bool,
): int {
    var failures = 0;
    if (!circleIdValid) { failures += 1; }
    if (!controllerWcValid) { failures += 1; }
    if (!masterWcValid) { failures += 1; }
    if (!treasuryWcValid) { failures += 1; }
    if (targetAddressDeployed) { failures += 1; }
    if (!masterDeployed) { failures += 1; }
    if (!masterDataResponsive) { failures += 1; }
    if (!masterWalletResponsive) { failures += 1; }
    if (!masterCodeAvailable) { failures += 1; }
    return failures;
}

/// Evaluates overall preflight outcome label based on critical failures and warnings
fun evaluatePreflightReviewStatus(criticalFailures: int, warnings: int): string {
    if (criticalFailures > 0) {
        return "NO-GO";
    }
    return "GO FOR MANUAL REVIEW";
}

/// Validates mint amount: must be strictly positive and <= MAX_COINS (2^120 - 1)
fun validateMintAmount(amount: int): bool {
    return amount > 0 && amount <= MAX_COINS;
}

/// Validates cumulative supply overflow: initialSupply + amount <= MAX_COINS
fun canMintWithoutSupplyOverflow(initialSupply: int, amount: int): bool {
    if (initialSupply < 0 || initialSupply > MAX_COINS) {
        return false;
    }
    if (amount <= 0 || amount > MAX_COINS) {
        return false;
    }
    return initialSupply <= MAX_COINS - amount;
}

/// Validates whether the signer address matches the registered minter admin
fun isMinterAdminMatching(registeredAdmin: address?, signerAddress: address): bool {
    if (registeredAdmin == null) {
        return false;
    }
    return registeredAdmin! == signerAddress;
}

/// Evaluates expected code hash check:
/// Returns:
/// 0 = unconfigured / manual check
/// 1 = valid and matching (PASS)
/// 2 = malformed input (CRITICAL FAIL)
/// 3 = mismatch against observed state (CRITICAL FAIL)
fun evaluateExpectedCodeHashCheck(
    isConfigured: bool,
    isMalformed: bool,
    parsedValue: int,
    observedHash: int,
): int {
    if (!isConfigured) {
        return 0; // manual
    }
    if (isMalformed) {
        return 2; // malformed FAIL
    }
    if (parsedValue != observedHash) {
        return 3; // mismatch FAIL
    }
    return 1; // matched PASS
}

/// Evaluates expected admin check:
/// Returns:
/// 0 = unconfigured / manual check
/// 1 = valid and matching (PASS)
/// 2 = malformed input (CRITICAL FAIL)
/// 3 = mismatch or onchain null (CRITICAL FAIL)
fun evaluateExpectedAdminCheck(
    isConfigured: bool,
    isMalformed: bool,
    expectedAdmin: address?,
    onChainAdmin: address?,
): int {
    if (!isConfigured) {
        return 0; // manual
    }
    if (isMalformed || expectedAdmin == null) {
        return 2; // malformed FAIL
    }
    if (onChainAdmin == null) {
        return 3; // onchain null mismatch FAIL
    }
    if (onChainAdmin! != expectedAdmin!) {
        return 3; // mismatch FAIL
    }
    return 1; // matched PASS
}

fun validateIntegerStringSyntax(raw: string): bool {
    val len = raw.calculateLength();
    if (len == 0) {
        return false;
    }
    var snake = raw.beginParse();
    var idx = 0;
    val depth = snake.depth();
    var valid = true;
    var isHex = false;
    var isBin = false;
    var firstChar = 0;

    repeat (depth + 1) {
        val bytesInCell = snake.remainingBitsCount() / 8;
        repeat (bytesInCell) {
            val c = snake.loadUint(8);
            if (idx == 0) {
                firstChar = c;
            } else if (idx == 1) {
                if (firstChar == 48 && (c == 120 || c == 88)) {
                    isHex = true;
                } else if (firstChar == 48 && (c == 98 || c == 66)) {
                    isBin = true;
                }
            }

            if (idx == 0) {
                if (c < 48 || c > 57) {
                    valid = false;
                }
            } else if (idx == 1) {
                if (!isHex && !isBin) {
                    if (c < 48 || c > 57) { valid = false; }
                }
            } else {
                if (isHex) {
                    if (!isValidHexChar(c)) { valid = false; }
                } else if (isBin) {
                    if (c != 48 && c != 49) { valid = false; }
                } else {
                    if (c < 48 || c > 57) { valid = false; }
                }
            }
            idx += 1;
        }
        if (snake.remainingRefsCount() > 0) {
            snake = snake.loadRef().beginParse();
        }
    }

    if (isHex && len <= 2) { return false; }
    if (isBin && len <= 2) { return false; }

    // TVM uint256 bounds check on length:
    // Hex: at most 64 hex digits + "0x" (len <= 66)
    // Bin: at most 256 binary digits + "0b" (len <= 258)
    // Decimal: at most 78 decimal digits (2^256 - 1 is 78 digits)
    if (isHex && len > 66) { return false; }
    if (isBin && len > 258) { return false; }
    if (!isHex && !isBin && len > 78) { return false; }

    return valid && idx == len;
}

/// Safely parses expected code hash string: returns [isConfigured, isMalformed, parsedValue]
fun parseExpectedCodeHash(rawString: string?): [bool, bool, int] {
    if (rawString == null) {
        return [false, false, 0];
    }
    val raw = rawString!;
    if (raw.equalTo("")) {
        return [false, false, 0];
    }
    if (!validateIntegerStringSyntax(raw)) {
        return [true, true, 0];
    }
    val parsed = ffi.parseInt(raw);
    if (parsed == null) {
        return [true, true, 0];
    }
    val valInt = parsed!;
    // TVM uint256 bound: [0, 2^256 - 1]
    if (valInt < 0 || valInt > 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff) {
        return [true, true, 0];
    }
    return [true, false, valInt];
}

fun isValidHexChar(c: int): bool {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
}

fun base64CharToVal(c: int): int {
    if (c >= 65 && c <= 90) { return c - 65; }        // 'A'..'Z' -> 0..25
    if (c >= 97 && c <= 122) { return c - 97 + 26; }   // 'a'..'z' -> 26..51
    if (c >= 48 && c <= 57) { return c - 48 + 52; }    // '0'..'9' -> 52..61
    if (c == 43 || c == 45) { return 62; }            // '+' or '-' -> 62
    if (c == 47 || c == 95) { return 63; }            // '/' or '_' -> 63
    return -1;
}

fun crc16UpdateByte(crc: int, byteVal: int): int {
    var c = (crc ^ (byteVal << 8)) & 0xffff;
    repeat (8) {
        if ((c & 0x8000) != 0) {
            c = ((c << 1) ^ 0x1021) & 0xffff;
        } else {
            c = (c << 1) & 0xffff;
        }
    }
    return c;
}

fun validateAddressStringSyntax(raw: string): bool {
    val len = raw.calculateLength();
    if (len != 48 && len != 66 && len != 67) {
        return false;
    }
    var snake = raw.beginParse();
    val depth = snake.depth();

    if (len == 66) {
        // Raw address: 0:<64 hex>
        var idx = 0;
        var valid = true;
        repeat (depth + 1) {
            val bytesInCell = snake.remainingBitsCount() / 8;
            repeat (bytesInCell) {
                val c = snake.loadUint(8);
                if (idx == 0 && c != 48) { valid = false; } // '0'
                if (idx == 1 && c != 58) { valid = false; } // ':'
                if (idx >= 2 && !isValidHexChar(c)) { valid = false; }
                idx += 1;
            }
            if (snake.remainingRefsCount() > 0) {
                snake = snake.loadRef().beginParse();
            }
        }
        return valid && idx == 66;
    }

    if (len == 67) {
        // Raw address: -1:<64 hex>
        var idx = 0;
        var valid = true;
        repeat (depth + 1) {
            val bytesInCell = snake.remainingBitsCount() / 8;
            repeat (bytesInCell) {
                val c = snake.loadUint(8);
                if (idx == 0 && c != 45) { valid = false; } // '-'
                if (idx == 1 && c != 49) { valid = false; } // '1'
                if (idx == 2 && c != 58) { valid = false; } // ':'
                if (idx >= 3 && !isValidHexChar(c)) { valid = false; }
                idx += 1;
            }
            if (snake.remainingRefsCount() > 0) {
                snake = snake.loadRef().beginParse();
            }
        }
        return valid && idx == 67;
    }

    // len == 48: User-friendly address (Base64 / Base64URL)
    // Decode 12 chunks of 4 Base64 chars into 36 bytes.
    // Verify tag (byte 0), workchain (byte 1), and CRC16 (bytes 34..35).
    var crc = 0;
    var byteCount = 0;
    var expectedCrcHigh = 0;
    var expectedCrcLow = 0;
    var tagByte = 0;
    var wcByte = 0;

    var chunkCharCount = 0;
    var c0 = 0;
    var c1 = 0;
    var c2 = 0;
    var allCharsValid = true;

    repeat (depth + 1) {
        val bytesInCell = snake.remainingBitsCount() / 8;
        repeat (bytesInCell) {
            val ch = snake.loadUint(8);
            if (chunkCharCount == 0) {
                c0 = ch;
            } else if (chunkCharCount == 1) {
                c1 = ch;
            } else if (chunkCharCount == 2) {
                c2 = ch;
            } else if (chunkCharCount == 3) {
                val c3 = ch;
                val v0 = base64CharToVal(c0);
                val v1 = base64CharToVal(c1);
                val v2 = base64CharToVal(c2);
                val v3 = base64CharToVal(c3);
                if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) {
                    allCharsValid = false;
                } else {
                    val b0 = ((v0 << 2) | (v1 >> 4)) & 0xff;
                    val b1 = (((v1 & 0x0f) << 4) | (v2 >> 2)) & 0xff;
                    val b2 = (((v2 & 0x03) << 6) | v3) & 0xff;

                    if (byteCount == 0) { tagByte = b0; }
                    if (byteCount < 34) { crc = crc16UpdateByte(crc, b0); }
                    else if (byteCount == 34) { expectedCrcHigh = b0; }
                    else if (byteCount == 35) { expectedCrcLow = b0; }
                    byteCount += 1;

                    if (byteCount == 1) { wcByte = b1; }
                    if (byteCount < 34) { crc = crc16UpdateByte(crc, b1); }
                    else if (byteCount == 34) { expectedCrcHigh = b1; }
                    else if (byteCount == 35) { expectedCrcLow = b1; }
                    byteCount += 1;

                    if (byteCount < 34) { crc = crc16UpdateByte(crc, b2); }
                    else if (byteCount == 34) { expectedCrcHigh = b2; }
                    else if (byteCount == 35) { expectedCrcLow = b2; }
                    byteCount += 1;
                }
                chunkCharCount = -1;
            }
            chunkCharCount += 1;
        }
        if (snake.remainingRefsCount() > 0) {
            snake = snake.loadRef().beginParse();
        }
    }

    if (!allCharsValid || byteCount != 36) {
        return false;
    }

    // Verify tag byte: lowest 6 bits must be 0x11 for valid TON user-friendly address
    if ((tagByte & 0x3f) != 0x11) {
        return false;
    }

    // Verify workchain byte: 0x00 (basechain) or 0xff (masterchain -1)
    if (wcByte != 0x00 && wcByte != 0xff) {
        return false;
    }

    // Verify CRC16
    val expectedCrc = (expectedCrcHigh << 8) | expectedCrcLow;
    return crc == expectedCrc;
}

/// Safely parses expected admin address string: returns [isConfigured, isMalformed, expectedAddress]
fun parseExpectedAdminAddress(rawString: string?): [bool, bool, address?] {
    if (rawString == null) {
        return [false, false, null];
    }
    val raw = rawString!;
    if (raw.equalTo("")) {
        return [false, false, null];
    }
    if (!validateAddressStringSyntax(raw)) {
        return [true, true, null];
    }
    try {
        val parsed = parseAddress(raw);
        return [true, false, parsed];
    } catch (e) {
        return [true, true, null];
    }
}
