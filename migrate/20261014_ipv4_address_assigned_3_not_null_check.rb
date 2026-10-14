# frozen_string_literal: true

# PostgreSQL does not test a NOT VALID check against the rows the table
# has, so adding it scans nothing. Inserts and updates must pass it, so it
# cannot come before the triggers, which give new rows a value. It comes
# before the backfill: rewriting every row can start autovacuum, and this
# exclusive lock would wait for it, with allocations queued behind.
#
# It is not named ipv4_address_assigned_not_null: PostgreSQL 18 gives that
# name to the NOT NULL constraint that SET NOT NULL adds.
Sequel.migration do
  up do
    run "ALTER TABLE ipv4_address ADD CONSTRAINT assigned_not_null CHECK (assigned IS NOT NULL) NOT VALID"
  end

  down do
    run "ALTER TABLE ipv4_address DROP CONSTRAINT assigned_not_null"
  end
end
