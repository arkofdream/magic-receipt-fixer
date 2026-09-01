CREATE OR REPLACE FUNCTION public.assert_journal_entry_balanced()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
  v_debit NUMERIC;
  v_credit NUMERIC;
  v_number TEXT;
BEGIN
  SELECT status, total_debit, total_credit, entry_number
    INTO v_status, v_debit, v_credit, v_number
  FROM public.journal_entries
  WHERE id = NEW.id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_status = 'POSTED' AND v_debit IS DISTINCT FROM v_credit THEN
    RAISE EXCEPTION 'Yevmiye fişi dengesiz: borç % / alacak % (Fiş No: %)',
      v_debit, v_credit, v_number
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;