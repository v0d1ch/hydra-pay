# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hydra Pay is a full-stack Haskell application providing a WebSocket API and live documentation interface for managing Hydra Heads (Layer-2 payment channels on Cardano). Built with the Obelisk framework (Reflex-based isomorphic Haskell). **Not yet production-ready.**

Current versions: Hydra Node 1.2.0, Cardano Node 10.5.3.

## Build Commands

```bash
# Enter development shell
nix-shell

# Build executable
nix-build -A exe --no-out-link

# Run with Obelisk (recommended for development, hot reload at localhost:8000)
ob run

# Build and deploy locally
mkdir test-app
ln -s $(nix-build -A exe --no-out-link)/* test-app/
cp -r config test-app
(cd test-app && ./hydra-pay)

# Build release (also used as CI check)
nix-build release.nix
```

## Architecture

### Three Cabal Packages

- **`common/`** — Shared types and API definitions (compiled for both GHC and GHCJS)
  - `Hydra.Types` — Core domain types: `Address`, `Lovelace`, `NodeId`, `TxId`, `WholeUTXO`
  - `Hydra.ClientInput` / `Hydra.ServerOutput` / `Hydra.Snapshot` — Hydra protocol messages
  - `HydraPay.Api` — Request/response types: `HeadCreate`, `HeadInit`, `HeadCommit`, `SubmitHeadTx`, `CloseHead`, etc.
  - `HydraPay.Config` — Configuration types (`ManagedDevnetMode` vs `ConfiguredMode`)

- **`backend/`** — Haskell server (GHC only, not buildable under GHCJS)
  - `Backend` — Entry point, routes WebSocket traffic
  - `HydraPay.Server` — Main business logic and WebSocket API handler (`/hydra/api`)
  - `HydraPay.Network` — Head network management
  - `Hydra.Devnet` — Manages local cardano/hydra nodes for devnet mode
  - `ParseConfig` — CLI argument parsing via optparse-applicative
  - `HydraPay.Logging` — Structured logging with severity levels

- **`frontend/`** — Reflex-DOM UI (compiles to JavaScript via GHCJS)

### Build System

Nix + Cabal + Obelisk. The `default.nix` imports Obelisk from `.obelisk/impl`, pulls Hydra via flake-compat, and cardano-node as a traditional Nix import. Dependencies are managed as git thunks in `dep/`. The `cardano-libs.nix` pins specific commits for cardano-api, cardano-base, cardano-ledger, etc.

### Key Design Patterns

- **WebSocket API**: Tagged request/response pattern — each request includes a `tagged_id` and `tagged_payload`, responses match the same ID. Server also pushes subscription-based updates.
- **Proxy Address Scheme**: Each participant gets a proxy address that holds their funds and fuel. Participants never share private keys.
- **Two Runtime Modes**: `ManagedDevnetMode` (default — spawns local devnet with 10 seeded addresses) and `ConfiguredMode` (connects to external Cardano/Hydra nodes).

### Key Directories

- `dep/` — Git thunks for pinned dependencies (hydra, cardano-node, reflex, etc.)
- `config/` — Runtime configuration (routes, API key)
- `livedoc-devnet/` — Scripts for live documentation devnet
- `static/` — Static assets served by the frontend

## Code Conventions

- GHC options: `-Wall -Wredundant-constraints -Wincomplete-uni-patterns -Wincomplete-record-updates -O -fno-show-valid-hole-fits`
- PRs must add **no new warnings**
- Common extensions enabled by default: `OverloadedStrings`, `LambdaCase`, `GADTs`, `ScopedTypeVariables`, `DeriveGeneric`, `FlexibleContexts`, `QuasiQuotes`
- Commit messages in imperative mood ("Add feature" not "Added feature")
- Include haddock documentation for new code
- Update `ChangeLog.md` for user-facing changes
