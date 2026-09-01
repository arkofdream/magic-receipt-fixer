ALTER TABLE public.journal_entries DROP CONSTRAINT IF EXISTS je_posted_balanced_check;

CREATE OR REPLACE FUNCTION public.assert_journal_entry_balanced()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'POSTED' AND NEW.total_debit IS DISTINCT FROM NEW.total_credit THEN
    RAISE EXCEPTION 'Yevmiye fişi dengesiz: borç % / alacak % (Fiş No: %)',
      NEW.total_debit, NEW.total_credit, NEW.entry_number
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_journal_entry_balanced() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_assert_journal_entry_balanced ON public.journal_entries;
CREATE CONSTRAINT TRIGGER trg_assert_journal_entry_balanced
AFTER INSERT OR UPDATE ON public.journal_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.assert_journal_entry_balanced();