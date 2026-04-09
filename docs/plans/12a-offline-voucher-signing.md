# Feature #12a: Offline Voucher Signing (Local Key as AuthorizedSigner)

**Status:** Planned
**Dependencies:** None (fix for existing Privy integration)
**Priority:** Critical — blocks offline-first premise
**Reviewed by:** systems-architect agent (2026-04-09), architecture-reviewer agent (2026-04-09)

## Problem

When Privy is active, `PrivyWalletProvider.signVoucher()` calls Privy's MPC signing API over the internet. No internet = no signature = no payment = no inference. This breaks the core Janus premise: offline AI inference for rural/disaster areas.

```
Current flow (broken offline):
  handleQuote → createVoucherAuthorization → walletProvider.signVoucher()
                                              └── PrivyWalletProvider
                                                  └── wallet.provider.request(rpc)  ← NEEDS INTERNET
```

## Solution: Always Use Local Key as AuthorizedSigner

Privy handles **identity + funding only**. Voucher signing uses the local `EthKeyPair` that already exists in `SessionManager` — fully offline.

```
New flow (works offline):
  handleQuote → createVoucherAuthorization → walletProvider.signVoucher()
                                              └── LocalWalletProvider(keyPair: ethKeyPair)
                                                  └── keyPair.sign()  ← PURE LOCAL CRYPTO

  Channel setup (online, at edge):
    authorizedSigner = ethKeyPair.address  (local key, ALWAYS)
    payer = ethKeyPair.address             (local key, handles on-chain txs)
    Privy wallet = user identity + can fund payer via transfer
```

### Why this works

1. `authorizedSigner` is set at channel-open time (on-chain, while internet is available)
2. Provider verifies vouchers via `ecrecover(signature) == channel.authorizedSigner`
3. Local key signs the voucher → `ecrecover` matches → verification passes
4. Works identically whether online or offline — no conditional paths
5. Channel struct already supports separate `payer` and `authorizedSigner` fields (both become local key)

### What Privy is still used for

- **User identity:** Email OTP login, wallet address as user identifier
- **Future funding:** Privy wallet can transfer funds to the local payer key (when fiat on-ramp is added)
- **Account recovery:** Privy's MPC-TSS recovery flow protects the identity wallet

### What changes vs current behavior

Currently with Privy active:
- `authorizedSigner` = Privy wallet address (MPC-TSS key)
- `walletProvider` = `PrivyWalletProvider` (signs via network)
- On-chain payer = local `EthKeyPair`

After this change:
- `authorizedSigner` = local `EthKeyPair` address (always)
- `walletProvider` = `LocalWalletProvider` (signs locally, always)
- On-chain payer = local `EthKeyPair` (unchanged)
- Privy wallet = identity only (not involved in payment channel)

### Behavioral changes to note

- **Multi-device:** If a user logs into Privy on two devices, each device generates a different local `EthKeyPair` and opens its own channel. Previously both devices shared a Privy address (though separate channels). This is arguably better for isolation — each device's channel is independent.

---

## Implementation Steps

### Step 1: Fix restore init — always restore local ETH keypair

**File:** `JanusApp/JanusClient/SessionManager.swift`, lines 79-87

**Problem (pre-existing bug):** When Privy is active, the restore init sets `self.walletProvider = PrivyWalletProvider` but never restores `self.ethKeyPair` from `persisted.ethPrivateKeyHex`. The local key is regenerated on every app restart, orphaning the old on-chain channel. This bug exists today but becomes critical with this change since the local key is now the sole `authorizedSigner`.

**Current code:**
```swift
// Use injected wallet provider (Privy) or restore local ETH keypair
if let wp = walletProvider {
    self.walletProvider = wp
    print("Using injected wallet provider: \(wp.address)")
} else if let ethHex = persisted.ethPrivateKeyHex, let ethKP = try? EthKeyPair(hexPrivateKey: ethHex) {
    self.ethKeyPair = ethKP
    self.walletProvider = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)
    print("Restored ETH keypair: \(ethKP.address)")
}
```

**New code:**
```swift
// Always restore local ETH keypair if persisted (used for on-chain ops AND voucher signing)
if let ethHex = persisted.ethPrivateKeyHex {
    do {
        let ethKP = try EthKeyPair(hexPrivateKey: ethHex)
        self.ethKeyPair = ethKP
        print("Restored ETH keypair: \(ethKP.address)")
    } catch {
        // Key data corrupted — log explicitly. setupTempoChannel will generate a new key,
        // but the old on-chain channel (if any) is stranded.
        print("WARNING: Failed to restore ETH keypair from persisted data: \(error). A new key will be generated, which may orphan an existing on-chain channel.")
    }
}

// Capture Privy identity address for logging/display (not used for signing)
if let wp = walletProvider {
    self.privyIdentityAddress = wp.address
    print("Privy identity present: \(wp.address) (identity only, not used for signing)")
}

// walletProvider is set later in setupTempoChannel() — always LocalWalletProvider
```

**Impact:** Local key survives app restarts, channel ID stays stable, on-chain channel is not orphaned. Corrupted key data is logged explicitly instead of silently swallowed.

### Step 2: Modify `SessionManager.setupTempoChannel()`

**File:** `JanusApp/JanusClient/SessionManager.swift`, lines 153-163

**Current code:**
```swift
if let wp = walletProvider {
    // Privy wallet signs vouchers; local key pays on-chain
    signerAddress = wp.address
    let sigAddr = wp.address.checksumAddress
    os_log("CLIENT_SIGNER_ADDRESS=%{public}@ (Privy wallet)", log: smokeLog, type: .default, sigAddr)
    print("CLIENT SIGNER ADDRESS (Privy): \(sigAddr)")
} else {
    // No Privy — local key does both
    signerAddress = ethKP.address
    self.walletProvider = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)
}
```

**New code:**
```swift
// Always use local key as authorizedSigner — works offline.
// Privy wallet (if present) is identity/funding only.
signerAddress = ethKP.address
self.walletProvider = LocalWalletProvider(keyPair: ethKP, rpcURL: tempoConfig.rpcURL)

let sigAddr = ethKP.address.checksumAddress
os_log("CLIENT_SIGNER_ADDRESS=%{public}@ (local key, offline-capable)", log: smokeLog, type: .default, sigAddr)
print("CLIENT SIGNER ADDRESS (local, offline-capable): \(sigAddr)")

// Log Privy identity separately if present
if let injectedWP = walletProvider, !(injectedWP is LocalWalletProvider) {
    os_log("CLIENT_PRIVY_IDENTITY=%{public}@", log: smokeLog, type: .default, injectedWP.address.checksumAddress)
    print("PRIVY IDENTITY (not used for signing): \(injectedWP.address.checksumAddress)")
}
```

**Note on `walletProvider` parameter:** `setupTempoChannel` accesses the `walletProvider` property on `self`. Before this code runs, Step 1 ensures `self.walletProvider` is nil (not yet set). The injected Privy wallet provider is passed through `ClientEngine` → `SessionManager.create()`/`.restore()` as a constructor parameter, stored temporarily, but overwritten here with `LocalWalletProvider`. To check if Privy is present, we test against the constructor parameter — but since it's already been cleared in Step 1, we need to capture it. See implementation detail below.

**Implementation detail:** Add a `privyIdentityAddress: EthAddress?` property to `SessionManager` that captures the Privy wallet address at construction time (for logging/display), separate from the `walletProvider` used for signing.

### Step 2a: Fix `create()` init — don't store Privy as walletProvider

**File:** `JanusApp/JanusClient/SessionManager.swift`, line 113-123

**Problem:** The private `create()` init stores the injected wallet provider directly:

```swift
private init(keyPair: JanusKeyPair, grant: SessionGrant, walletProvider: (any WalletProvider)?, store: JanusStore) {
    ...
    self.walletProvider = walletProvider  // ← Stores Privy here (line 120)
    self.store = store
    persist()
}
```

Between this init and the subsequent `setupTempoChannel()` call, `self.walletProvider` points to Privy. While safe in practice (no channel exists yet, so `createVoucherAuthorization` would fail at the `guard let ch = channel` check), it's brittle. A future change to timing could reintroduce Privy as the signer.

**New code:**
```swift
private init(keyPair: JanusKeyPair, grant: SessionGrant, walletProvider: (any WalletProvider)?, store: JanusStore) {
    ...
    // Don't store Privy as walletProvider — setupTempoChannel() always sets LocalWalletProvider.
    // Capture Privy address for identity/display only.
    if let wp = walletProvider {
        self.privyIdentityAddress = wp.address
    }
    self.store = store
    persist()
}
```

### Step 3: No migration needed — channels are reconstructed on launch

**Key insight from review:** `Channel` is **not persisted** in `PersistedClientSession`. It is reconstructed via `setupTempoChannel()` on every app launch. There is no persisted `signerAddress` to compare against.

This means Step 2 alone is sufficient: once `setupTempoChannel` always uses the local key, every session (new or restored) automatically gets the correct signer. No explicit migration logic needed.

**However — stranded on-chain deposits:** Users who previously had an on-chain channel opened with Privy as `authorizedSigner` will now get a different `channelId` (because `authorizedSigner` is an input to `computeId()`). The old on-chain channel still has locked funds.

**Mitigation (deferred to follow-up):** Add a "close old channel" utility that:
1. Reads the old channel ID from the on-chain escrow (by iterating known payer+payee+salt combinations)
2. Calls `closeChannel()` to return remaining deposit to the payer
3. This requires the payer key (local `EthKeyPair`) — which we now always restore (Step 1)

This is a non-blocking concern for MVP: testnet deposits have no real value. For mainnet, this utility must exist before launch. Track as a separate ticket.

### Step 4: Provider-side channel mismatch (no code change needed)

When a client reconnects with a new `channelId` (local key as signer vs old Privy signer), the provider sees a new channel in `ChannelInfo`. The existing `ProviderEngine` logic already handles this:
- If `channels[sessionID]` exists with a different `channelId`, it replaces the channel (line added in the SEQUENCE_MISMATCH fix)
- Unsettled vouchers from the old Privy-signed channel remain valid for settlement — `ecrecover` on those vouchers returns the Privy address, which matches the old on-chain channel's `authorizedSigner`

**No provider code change needed.**

### Step 5: Tests

**File:** `Tests/JanusSharedTests/WalletProviderTests.swift` (existing)

Add/update tests:
1. **`testVoucherSignedWithLocalKey_verifiesAgainstLocalSigner`** — create channel with local key as authorizedSigner, sign voucher with local key, verify with `VoucherVerifier` → pass
2. **`testVoucherSignedWithLocalKey_settlesOnChain`** — (integration) sign voucher with local key, verify `ecrecover` returns local key address (matches `authorizedSigner`)
3. **`testPrivySignedVoucher_failsAgainstLocalKeyChannel`** — (negative test) sign voucher with a different key (simulating Privy), verify it fails against a channel where `authorizedSigner` is the local key. Catches regressions where signing accidentally routes back through Privy.

**File:** `JanusApp/JanusClientTests/` (new or existing)

4. **`testOfflineVoucherSigning_noNetworkRequired`** — create SessionManager with mock Privy wallet, call `createVoucherAuthorization()` — should succeed without any network calls (mock wallet's `signVoucher` should NOT be called)
5. **`testRestoreInit_alwaysRestoresEthKeyPair`** — persist a session with `ethPrivateKeyHex`, restore with a mock Privy wallet injected — verify `ethKeyPair` is restored (not nil), and matches the persisted key
6. **`testCreateInit_alwaysUsesLocalSignerEvenWithPrivy`** — call `SessionManager.create()` with a mock Privy wallet, then `setupTempoChannel()` — verify `walletProvider` is `LocalWalletProvider`, NOT the injected Privy mock
7. **`testRestoreInit_corruptedEthKey_logsWarning`** — persist a session with invalid `ethPrivateKeyHex`, restore — verify `ethKeyPair` is nil (new key generated in `setupTempoChannel`), system remains functional

---

## Files Summary

| File | Action | Est. Lines Changed |
|------|--------|-------------------|
| `JanusClient/SessionManager.swift` | Modify (restore init, Step 1) | ~15 |
| `JanusClient/SessionManager.swift` | Modify (`create()` init, Step 2a) | ~6 |
| `JanusClient/SessionManager.swift` | Modify (`setupTempoChannel`, Step 2) | ~15 |
| `JanusClient/SessionManager.swift` | Add `privyIdentityAddress` property | ~5 |
| `JanusSharedTests/WalletProviderTests.swift` | Add tests (1, 2, 3) | ~40 |
| `JanusClientTests/` (new or existing) | Add tests (4, 5, 6, 7) | ~50 |

**Total:** ~131 lines across 2-3 files. Small, surgical change.

---

## What Does NOT Change

- `PrivyAuthManager.swift` — still handles login/logout, still creates embedded wallet
- `PrivyWalletProvider.swift` — still exists, could be used for future funding flows
- `ClientEngine.swift` — still accepts and passes through wallet provider (minimal comment update only)
- `Channel.swift` — struct unchanged, already supports separate payer/authorizedSigner
- `VoucherVerifier.swift` — unchanged, already verifies against `channel.authorizedSigner`
- `ChannelOpener.swift` — unchanged, already uses `LocalWalletProvider` for on-chain ops
- `ProviderEngine.swift` — unchanged, handles new channelId via existing channel-replacement logic
- Provider-side code — entirely unchanged, verifies vouchers via `ecrecover` as before
- On-chain escrow contract — unchanged, `settle()` uses `ecrecover` against `authorizedSigner`

---

## Verification

1. **Unit tests** — all existing + new tests pass
2. **Online test** — login with Privy, connect to provider, send queries — vouchers signed locally, channel opens with local key
3. **Offline test** — disable WiFi+cellular on iPhone, send queries — vouchers still sign (local crypto), inference works via MPC/AWDL
4. **Settlement test** — re-enable internet, provider settles on-chain — `ecrecover` returns local key address, matches `authorizedSigner`, settlement succeeds
5. **Restart test** — force-quit app, relaunch — `ethKeyPair` restored, same channel ID, queries work without re-opening channel
6. **Create path test** — fresh session with Privy → verify `walletProvider` is `LocalWalletProvider` after setup

---

## Risks and Mitigations

### Key loss / device wipe

The local `EthKeyPair` is device-bound. Losing the device means losing the signing key. However:
- The payer key (same key) can call `closeChannel()` — but if the key is lost, neither payer nor signer can act
- The escrow contract has a timeout mechanism: after the timeout period, the channel can be finalized by either party
- **Mitigation:** For mainnet, add optional encrypted key backup (to iCloud Keychain or Privy's secure storage). Not needed for testnet.

### Stranded deposits from old Privy-signed channels

Users who previously opened channels with Privy as `authorizedSigner` will have funds locked in the old on-chain channel. The new channel (local key signer) will require a fresh deposit.
- **Testnet:** Not a real concern (testnet funds are free via faucet)
- **Mainnet:** Must build a channel-close utility before launch. Track as separate ticket.

---

## Design Rationale

### Why not keep Privy for signing and add offline fallback?

Conditional paths (Privy when online, local key when offline) would require:
- Two different `authorizedSigner` values per channel (or two channels)
- Provider must accept vouchers from either signer
- On-chain escrow only has one `authorizedSigner` per channel — can't verify both
- Complexity explosion for marginal benefit

### Why not export Privy's key share for offline use?

Privy's MPC-TSS design explicitly prevents key extraction — that's the security model. The device holds one key share, Privy holds the other. Neither share alone can sign. This is a feature, not a bug — but it's incompatible with offline operation.

### Why this approach is safe

The local `EthKeyPair` is already persisted in `client_session_{providerID}.json` (as `ethPrivateKeyHex`). It survives app restarts. The key is device-bound — losing the device means losing the key, but:
- Channel deposits are recoverable via on-chain timeout/close (payer can close)
- Privy wallet (user identity) is recoverable via Privy's recovery flow
- The local key's only role is authorizing voucher payments up to the deposited amount

The security boundary is: **the local key can only authorize spending funds that were already deposited into the channel.** It cannot access funds beyond the deposit. The maximum loss from key compromise is the channel deposit amount.
