# Janus v1 Demo Script

## Prerequisites

1. **Mac** (Apple Silicon) with Xcode installed and model cached
2. **iPhone** on the same local network (or within Bluetooth range) with Developer Mode enabled
3. Model `mlx-community/Qwen3-4B-4bit` downloaded (~2.3 GB, cached after first run)

## Setup

### 1. Build and launch the provider (Mac)

```bash
cd ~/projects/janus/JanusApp
xcodebuild -project JanusApp.xcodeproj -scheme JanusProvider -destination "platform=macOS" build
```

Launch from DerivedData:
```bash
open ~/Library/Developer/Xcode/DerivedData/JanusApp-*/Build/Products/Debug/JanusProvider.app
```

Wait for:
- Model status: **Ready** (green dot)
- Network status: **Advertising** (green dot)

### 2. Build and deploy the client (iPhone)

```bash
security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db
cd ~/projects/janus/JanusApp
xcodebuild -project JanusApp.xcodeproj -scheme JanusClient \
  -destination "id=00008140-001E7526022B001C" \
  -allowProvisioningUpdates build
```

Deploy:
```bash
xcrun devicectl device install app \
  --device 00008140-001E7526022B001C \
  ~/Library/Developer/Xcode/DerivedData/JanusApp-*/Build/Products/Debug-iphoneos/JanusClient.app
```

Launch JanusClient on the iPhone.

### 3. Connect

1. On iPhone, tap **Scan** in the top-right corner
2. Accept the MPC connection dialog if prompted
3. Wait for the provider info card to appear (shows pricing, model, tasks)
4. Tap **Start Using Provider**

You should see the prompt screen with **100 credits remaining** and a full blue balance bar.

---

## Demo 1: Translate

**Goal**: Show real-time translation from English to Spanish over local inference.

1. Select the **Translate** tab (should be selected by default)
2. Target language: **Spanish** (pre-filled)
3. Enter text:
   ```
   The weather is beautiful today. Let's go for a walk in the park.
   ```
4. Tap **Submit**
5. Watch the flow:
   - Button shows "Getting quote..." (quote round-trip)
   - Status shows "3 credits (small)" (pricing tier)
   - Button shows "Processing..." (MLX inference)
   - Response card appears with Spanish translation

**On the Mac**: Request log shows the translate entry with +3 credits, stats update.

**Expected cost**: 3 credits (small tier). Balance: **97 credits**.

---

## Demo 2: Rewrite

**Goal**: Show style transformation — rewrite casual text in a professional tone.

1. Select the **Rewrite** tab
2. Style: **Professional** (pre-filled)
3. Enter text:
   ```
   hey so basically our app is kinda slow and users are mad about it, we gotta fix it asap
   ```
4. Tap **Submit**
5. Response appears with professionally rewritten text

**Try again** with style **Formal** and the same text to show the difference.

**Expected cost**: 3 credits each (small tier). Balance: **91 credits** (after both).

---

## Demo 3: Summarize

**Goal**: Show summarization of a longer passage, triggering a higher pricing tier.

1. Select the **Summarize** tab
2. Enter text (medium-length for 5-credit tier):
   ```
   Artificial intelligence has transformed numerous industries over the past decade. In healthcare, AI systems now assist with medical imaging analysis, drug discovery, and patient diagnosis. The financial sector uses AI for fraud detection, algorithmic trading, and risk assessment. Transportation has seen advances in autonomous vehicles and route optimization. Education benefits from personalized learning platforms that adapt to individual student needs. Meanwhile, the creative industries are exploring AI-generated art, music, and writing tools that augment human creativity rather than replace it.
   ```
3. Tap **Submit**
4. Response shows a concise summary

**Expected cost**: 5 credits (medium tier, 200-500 chars). Balance: **86 credits**.

---

## Demo 4: Edge cases (optional)

### Insufficient credits
- After many requests, the balance bar turns red below 20%
- When credits drop below 3 (smallest tier), the submit button disables and a warning appears

### Provider disconnect
- While on the prompt screen, quit JanusProvider on the Mac
- iPhone shows orange "Provider disconnected" banner
- After 2 seconds, auto-navigates back to discovery screen

### Multiple sequential requests
- Submit several requests in a row
- Expand the **History** section to see all past results with task types, prompts, and responses
- On Mac, the request log shows all entries with timestamps and credits

---

## Key talking points

- **Fully offline**: After initial connection, no internet needed. All inference runs locally on the Mac's GPU via MLX.
- **Real cryptographic payments**: Ed25519 signatures (CryptoKit), 9-step spend verification, provider-signed receipts. Not a mock — structurally identical to the production MPP flow.
- **Cumulative spend model**: Each request increases a monotonic spend counter. The provider verifies the sequence is strictly increasing — replay or double-spend is impossible.
- **Sub-second quotes**: The quote round-trip over MPC adds <50ms. Worth it for MPP protocol fidelity.
- **Three pricing tiers**: Small (3), Medium (5), Large (8) — classified by prompt length, keeping pricing simple and predictable.
