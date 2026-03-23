# Janus Worklog

## 2026-03-23

### M1: Local inference on Mac (standalone)

#### Setup
- Created project directory at `~/projects/janus/`
- Wrote end-state design document (`DESIGN.md`)
- Wrote v1 spec (`V1_SPEC.md`)
- Wrote PRD with protocol schema, data model, milestones, decision log (`PRD.md`)

#### Decisions made
- D1: Inference model — `mlx-community/Qwen3-4B-4bit` (Qwen3-4B, 4-bit quantization, ~2.3GB)
- D2: Session grant delivery — Option B (client presents signed grant on first contact, MPP-aligned)
- D3: Transport — Multipeer Connectivity (not raw BLE)
- D4: Quote round-trip — keep it (MPP challenge fidelity, <50ms cost)
- D5: Backend — Swift (Vapor) for shared crypto code

#### Implementation
- Created SPM package with `JanusShared` library and `JanusProvider` executable targets
- Implemented `TaskType` enum (translate, rewrite, summarize)
- Implemented `PricingTier` with classify-by-prompt-length logic (small/medium/large → 3/5/8 credits)
- Implemented `PromptTemplates` with system prompts per task type
- Implemented `MLXRunner` actor wrapping mlx-swift-lm's `ChatSession` for single-turn inference
- Implemented CLI entry point with interactive prompt loop

#### Issues encountered
- `swift build` cannot compile Metal shaders — MLX requires `xcodebuild` to generate `default.metallib` in `mlx-swift_Cmlx.bundle`
- Required Xcode.app installation (was only Command Line Tools)
- Required Metal Toolchain download (`xcodebuild -downloadComponent MetalToolchain`)
- Qwen3 defaults to "thinking mode" with `<think>` tags — fixed with `/no_think` prompt prefix and `stripThinkingTags` safety net

#### Build commands
- Build: `xcodebuild -scheme janus-provider -destination "platform=macOS" build`
- Test: `xcodebuild test -scheme Janus-Package -destination "platform=macOS" -only-testing:JanusSharedTests`
- Run: `/Users/soubhik/Library/Developer/Xcode/DerivedData/janus-*/Build/Products/Debug/janus-provider`

#### Results
- All 3 task types working: translate (0.3s), summarize (0.6s), rewrite (0.5s)
- Pricing tier classification correct at boundaries
- 6/6 unit tests passing
- Model cached at HuggingFace default cache path (~2.3GB, downloaded once)

#### Status: M1 COMPLETE
