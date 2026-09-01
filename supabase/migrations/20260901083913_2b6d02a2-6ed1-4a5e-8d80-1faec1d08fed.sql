CREATE OR REPLACE FUNCTION public.sync_journal_entry_totals()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry_id UUID;
BEGIN
  v_entry_id := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
  IF v_entry_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  UPDATE public.journal_entries je
  SET total_debit = COALESCE(s.d, 0),
      total_credit = COALESCE(s.c, 0),
      updated_at = now()
  FROM (
    SELECT SUM(debit) AS d, SUM(credit) AS c
    FROM public.journal_lines
    WHERE journal_entry_id = v_entry_id
  ) s
  WHERE je.id = v_entry_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_journal_entry_totals ON public.journal_lines;
CREATE TRIGGER trg_sync_journal_entry_totals
AFTER INSERT OR UPDATE OR DELETE ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.sync_journal_entry_totals();

UPDATE public.journal_entries je
SET total_debit = COALESCE(s.d, 0),
    total_credit = COALESCE(s.c, 0)
FROM (
  SELECT journal_entry_id, SUM(debit) AS d, SUM(credit) AS c
  FROM public.journal_lines
  GROUP BY journal_entry_id
) s
WHERE je.id = s.journal_entry_id
  AND (je.total_debit IS DISTINCT FROM s.d OR je.total_credit IS DISTINCT FROM s.c);