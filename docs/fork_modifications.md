# SupaBase Jump Fork Modifications for LOOVE OS

## Changes from Upstream

### 1. System Vault Awareness (P1) — Implemented
- Added `systemVaultId` setting (default: `loove-system`)
- `SyncEngine.fetchAllRemoteRows()` queries both user vault and system vault
- `fullSync()` skips pushing files that belong to system-generated notes
- `startRealtimeListener()` subscribes to both vault channels
- `isSystemGeneratedNote()` utility detects translation layer notes via frontmatter

### 2. Conflict Resolution (P2) — Implemented
- `isServerAuthoritative()` returns true for system-generated notes
- System notes always pull from server (Postgres trigger is source of truth)
- User notes retain existing mtime-based conflict resolution
- Realtime handler uses server-authoritative logic for system notes

### 3. Version
- Bumped to `1.2.0-loove`
- Package name: `supabase-jump-loove`

### 4. Pending (P3)
- Embedding status indicator in status bar
- Test suite with Vitest
