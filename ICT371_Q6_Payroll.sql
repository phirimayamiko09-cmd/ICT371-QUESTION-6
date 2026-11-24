-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- PostgreSQL. Run the whole file in one go (psql -f, or the pgAdmin Query Tool).

DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path = q6_payroll, public;

------------------------------------------------------------------
-- (a) Database and seed data
------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    -- pay_month must be the first day of a month
    CONSTRAINT ck_pay_month_start
        CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- Employees: 4 active and 1 who becomes inactive after two months of payroll
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('Alice Banda',   5000.00, 800.00, 600.00, TRUE),
 ('Brian Mwale',   4200.00, 500.00, 450.00, TRUE),
 ('Chanda Phiri',  6100.00, 900.00, 750.00, TRUE),
 ('Dalitso Zulu',  3500.00, 300.00, 300.00, TRUE),
 ('Esther Tembo',  4800.00, 600.00, 550.00, TRUE);   -- will be deactivated below

------------------------------------------------------------------
-- (b) Function: fn_net_pay
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q6_payroll, public
AS $$
DECLARE
    v_basic NUMERIC;
    v_allow NUMERIC;
    v_ded   NUMERIC;
    v_net   NUMERIC;
BEGIN
    SELECT basic_salary, allowance, deduction
      INTO v_basic, v_allow, v_ded
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_ded;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

------------------------------------------------------------------
-- (c) Procedure: pr_process_payroll (query FOR loop)
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
SET search_path = q6_payroll, public
AS $$
DECLARE
    rec     RECORD;
    v_gross NUMERIC;
    v_net   NUMERIC;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
          FROM employees
         WHERE active
         ORDER BY employee_id
    LOOP
        -- raises (and aborts the whole call) for a negative net pay
        v_net   := fn_net_pay(rec.employee_id);
        v_gross := rec.basic_salary + rec.allowance;

        -- missing rows are inserted; existing rows are left unchanged
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

------------------------------------------------------------------
-- (d) Trigger: log actual basic_salary changes
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q6_payroll, public
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

------------------------------------------------------------------
-- Seed payroll for two months through the procedure
------------------------------------------------------------------
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- Esther leaves: she becomes inactive but keeps her history
UPDATE employees SET active = FALSE WHERE employee_id = 5;

-- Process a third month: Esther is skipped
CALL pr_process_payroll(DATE '2026-11-01');

-- Re-running the same month leaves existing rows unchanged
CALL pr_process_payroll(DATE '2026-11-01');
SELECT pay_month, COUNT(*) AS rows_per_month
  FROM payroll GROUP BY pay_month ORDER BY pay_month;

------------------------------------------------------------------
-- (e) View: v_payroll_report (history kept for inactive employees)
------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
  FROM payroll p
  JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

------------------------------------------------------------------
-- (f) Index: report filtered by pay_month across all employees
------------------------------------------------------------------
-- The unique index (employee_id, pay_month) starts with employee_id, so it
-- cannot be used efficiently to search by pay_month alone. A single-column
-- index on pay_month serves this report without duplicating the unique one.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

-- Tables this small normally get a sequential scan; discourage it to show the index.
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

------------------------------------------------------------------
-- (g) Scheduled job (pg_cron): 02:00 on the 1st of each month,
--     passing the first date of the previous month
------------------------------------------------------------------
-- One-off setup (superuser; pg_cron must be in shared_preload_libraries):
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'monthly-payroll',
    '0 2 1 * *',
    $$CALL q6_payroll.pr_process_payroll(
          (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active FROM cron.job;

-- Inspect run history
SELECT jobid, status, return_message, start_time, end_time
  FROM cron.job_run_details
 ORDER BY start_time DESC
 LIMIT 10;

-- To remove the job: SELECT cron.unschedule('monthly-payroll');

------------------------------------------------------------------
-- Tests
------------------------------------------------------------------
-- 1. Trigger: a real salary change is logged, an unchanged one is not
UPDATE employees SET basic_salary = 5500 WHERE employee_id = 1;  -- logged
UPDATE employees SET basic_salary = 5500 WHERE employee_id = 1;  -- not logged
SELECT * FROM salary_audit;

-- 2. Function
SELECT fn_net_pay(1);

-- 3. Invalid month (not the first day) is rejected
DO $$
BEGIN
    CALL pr_process_payroll(DATE '2026-12-15');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

-- 4. Unknown employee is rejected
DO $$
BEGIN
    PERFORM fn_net_pay(999);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

-- 5. A negative net pay fails the whole call and inserts nothing
BEGIN;
UPDATE employees SET deduction = 99999 WHERE employee_id = 4;
DO $$
BEGIN
    CALL pr_process_payroll(DATE '2026-12-01');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;
SELECT COUNT(*) AS dec_rows FROM payroll WHERE pay_month = DATE '2026-12-01';  -- 0
ROLLBACK;
