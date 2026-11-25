--Q4
--a

CREATE TABLE patients (
patient_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
full_name TEXT NOT NULL
);
CREATE TABLE doctors (
doctor_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
full_name TEXT NOT NULL
);
CREATE TABLE appointments (
appointment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
patient_id BIGINT NOT NULL REFERENCES patients(patient_id),
doctor_id BIGINT NOT NULL REFERENCES doctors(doctor_id),
appointment_day DATE NOT NULL,
slot_time TIME NOT NULL
CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
status TEXT NOT NULL DEFAULT 'BOOKED'
CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
CREATE TABLE clinic_summary (
summary_date DATE PRIMARY KEY,
booked_count BIGINT NOT NULL,
attended_count BIGINT NOT NULL,
cancelled_count BIGINT NOT NULL
);

--b
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id BIGINT, p_day DATE)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_count BIGINT;
BEGIN
PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
IF NOT FOUND THEN
RAISE EXCEPTION 'Unknown doctor ID %', p_doctor_id;
END IF;
IF p_day IS NULL THEN
RAISE EXCEPTION 'Appointment day is required';
END IF;
SELECT COUNT(*) INTO v_count FROM appointments
WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
RETURN v_count; -- COUNT(*) is 0 when the day has no bookings
END; $$;

--c
CREATE OR REPLACE PROCEDURE pr_book_appointment(
p_patient_id BIGINT, p_doctor_id BIGINT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient ID %', p_patient_id; END IF;
PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor ID %', p_doctor_id; END IF;
IF p_day IS NULL OR p_day < CURRENT_DATE THEN
RAISE EXCEPTION 'Date cannot be in the past';
END IF;
IF p_slot IS NULL OR p_slot NOT IN
(TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
RAISE EXCEPTION 'Unsupported appointment slot';
END IF;
INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END; $$;


--d
CREATE OR REPLACE FUNCTION trg_check_appointment_clash()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
IF NEW.status <> 'CANCELLED' AND EXISTS (
SELECT 1 FROM appointments a
WHERE a.doctor_id = NEW.doctor_id
AND a.appointment_day = NEW.appointment_day
AND a.slot_time = NEW.slot_time
AND a.status <> 'CANCELLED'
AND a.appointment_id <> COALESCE(NEW.appointment_id, -1) -- exclude the row being changed
) THEN
RAISE EXCEPTION 'Doctor already has an appointment in that slot';
END IF;
RETURN NEW;
END; $$;
CREATE TRIGGER appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments FOR EACH ROW
EXECUTE FUNCTION trg_check_appointment_clash();
-- Optional extra protection against two concurrent transactions (needs btree_gist):
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE appointments ADD CONSTRAINT no_doctor_slot_clash
EXCLUDE USING gist (doctor_id WITH =, appointment_day WITH =, slot_time WITH =)
WHERE (status <> 'CANCELLED');

--e
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name,
d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';


--f
CREATE INDEX idx_appointments_day_doctor ON appointments(appointment_day, doctor_id);
-- Matching query and plan:
EXPLAIN SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;


--g
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
IF p_day IS NULL THEN RAISE EXCEPTION 'Summary date is required'; END IF;
INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
SELECT p_day,
COUNT(*) FILTER (WHERE status = 'BOOKED'),
COUNT(*) FILTER (WHERE status = 'ATTENDED'),
COUNT(*) FILTER (WHERE status = 'CANCELLED')
FROM appointments WHERE appointment_day = p_day
ON CONFLICT (summary_date) DO UPDATE SET
booked_count = EXCLUDED.booked_count,
attended_count = EXCLUDED.attended_count,
cancelled_count = EXCLUDED.cancelled_count;
END; $$;
-- Schedule: every day at 01:00 for the previous day.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('clinic-daily-summary', '0 1 * * *',
$$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);


--seeds
INSERT INTO patients(full_name) VALUES ('Leya Phiri'), ('Peter Zulu'), ('Misozi Banda');
INSERT INTO doctors(full_name) VALUES ('Dr. Chola'), ('Dr. Tembo'), ('Dr. Mbewe');
-- Six appointments (two today so that v_today_appointments has rows).
CALL pr_book_appointment(1, 1, CURRENT_DATE, TIME '09:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE, TIME '10:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, TIME '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, TIME '10:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, TIME '11:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, TIME '12:00');
SELECT fn_daily_load(1, CURRENT_DATE + 1) AS dr_chola_tomorrow; -- 1
SELECT fn_daily_load(1, CURRENT_DATE + 30) AS no_bookings; -- 0
SELECT * FROM v_today_appointments ORDER BY slot_time;
-- A cancelled slot becomes free again.
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 3;
CALL pr_book_appointment(2, 1, CURRENT_DATE + 1, TIME '09:00');
CALL pr_refresh_clinic_summary(CURRENT_DATE + 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE + 1); -- rerun replaces the row
SELECT * FROM clinic_summary;

