# frozen_string_literal: true

Sequel.migration do
  # Validating the check scans the table without an exclusive lock. With a
  # valid check, SET NOT NULL does not scan it again, so its exclusive lock
  # is brief. All of this commits together with the record of the
  # migration, so a failed run leaves the NOT VALID check for the next one.
  up do
    run "ALTER TABLE ipv4_address VALIDATE CONSTRAINT assigned_not_null"
    run "ALTER TABLE ipv4_address ALTER COLUMN assigned SET NOT NULL"
    run "ALTER TABLE ipv4_address DROP CONSTRAINT assigned_not_null"
  end

  # Add back the check of the previous migration, so that its down, or this
  # migration's up, can run next.
  down do
    run "ALTER TABLE ipv4_address ALTER COLUMN assigned DROP NOT NULL"
    run "ALTER TABLE ipv4_address ADD CONSTRAINT assigned_not_null CHECK (assigned IS NOT NULL) NOT VALID"
  end
end
