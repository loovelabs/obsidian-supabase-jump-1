-- ============================================================================
-- RLS Bypass for System Vault
-- ============================================================================
-- The translation layer inserts vault_files rows without a user_id
-- (system-generated notes). The default RLS policy requires
-- auth.uid() = user_id, which would block these inserts.
--
-- This policy allows:
-- 1. Triggers (SECURITY DEFINER functions) to write system vault rows
-- 2. Any authenticated user to READ system vault notes
-- 3. Only the owning user to write to their own vault (existing policy)
-- ============================================================================

-- Allow all authenticated users to SELECT system vault notes
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='vault_files' AND policyname='System vault read access'
  ) THEN
    CREATE POLICY "System vault read access" ON vault_files FOR SELECT
      USING (vault_id = 'loove-system');
  END IF;
END $$;

-- Allow service role (triggers) to INSERT/UPDATE system vault notes
-- Note: Triggers run as the function owner, which is typically the
-- postgres role. This policy ensures they can write to vault_files.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='vault_files' AND policyname='System vault write access'
  ) THEN
    CREATE POLICY "System vault write access" ON vault_files FOR ALL
      USING (vault_id = 'loove-system' AND user_id IS NULL)
      WITH CHECK (vault_id = 'loove-system' AND user_id IS NULL);
  END IF;
END $$;
