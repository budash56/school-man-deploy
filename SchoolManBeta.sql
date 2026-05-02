--
-- PostgreSQL database dump
--

-- Dumped from database version 17.3
-- Dumped by pg_dump version 17.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: attendance_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.attendance_status AS ENUM (
    'P',
    'A',
    'AE'
);


--
-- Name: course_instance_scope; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.course_instance_scope AS ENUM (
    'GRADE',
    'CLASS_GROUP'
);


--
-- Name: disciplinary_level; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.disciplinary_level AS ENUM (
    'green',
    'yellow',
    'red',
    'last_notice'
);


--
-- Name: user_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.user_role AS ENUM (
    'admin',
    'registrar',
    'teacher',
    'coordinator'
);


--
-- Name: check_attendance_slot_day(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_attendance_slot_day() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_dow int;
BEGIN
  IF NEW.slot_id IS NOT NULL THEN
    SELECT s.day_of_week INTO v_dow
    FROM public.timetable_slots s
    JOIN public.timetable_assignments ta ON ta.slot_id = s.slot_id
    WHERE ta.course_id = NEW.course_id AND ta.slot_id = NEW.slot_id;

    IF v_dow IS NULL THEN
      RAISE EXCEPTION 'Invalid course/slot combination';
    END IF;
    IF EXTRACT(ISODOW FROM NEW.date)::int <> v_dow THEN
      RAISE EXCEPTION 'Attendance date weekday must match the slot''s day_of_week';
    END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: check_course_grade_level(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_course_grade_level() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (SELECT ci.grade_level FROM public.course_instances ci WHERE ci.course_instance_id = NEW.course_instance_id)
     <> (SELECT cg.grade_level FROM public.class_groups cg WHERE cg.class_group_id = NEW.class_group_id)
  THEN
    RAISE EXCEPTION 'CourseInstance grade_level must match ClassGroup grade_level';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: check_excuse_editor(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_excuse_editor() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status = 'AE' AND OLD.status = 'A' THEN
    IF NEW.excused_by IS NULL OR NEW.excused_by <> OLD.recorded_by THEN
      RAISE EXCEPTION 'Only the teacher who recorded the absence can excuse it (v1 rule)';
    END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: check_grade_enrollment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_grade_enrollment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_year bigint;
BEGIN
  SELECT ci.school_year_id INTO v_year
  FROM public.courses c
  JOIN public.course_instances ci ON ci.course_instance_id = c.course_instance_id
  WHERE c.course_id = NEW.course_id;

  IF NOT EXISTS (
    SELECT 1
    FROM public.enrollments e
    JOIN public.courses c ON c.class_group_id = e.class_group_id
    JOIN public.course_instances ci ON ci.course_instance_id = c.course_instance_id
    WHERE e.student_id = NEW.student_id
      AND e.active
      AND ci.school_year_id = v_year
      AND c.course_id = NEW.course_id
  ) THEN
    RAISE EXCEPTION 'Student must be actively enrolled in the course''s class group for this school year';
  END IF;

  RETURN NEW;
END $$;


--
-- Name: check_room_double_booking(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_room_double_booking() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_room bigint;
BEGIN
  SELECT COALESCE(NEW.classroom_id, cg.classroom_id) INTO v_room
  FROM public.courses c
  JOIN public.class_groups cg ON cg.class_group_id = c.class_group_id
  WHERE c.course_id = NEW.course_id;

  IF EXISTS (
    SELECT 1
    FROM public.timetable_assignments ta
    JOIN public.courses c2 ON c2.course_id = ta.course_id
    JOIN public.class_groups cg2 ON cg2.class_group_id = c2.class_group_id
    WHERE ta.slot_id = NEW.slot_id
      AND COALESCE(ta.classroom_id, cg2.classroom_id) = v_room
      AND ta.assignment_id <> COALESCE(NEW.assignment_id, -1)
  ) THEN
    RAISE EXCEPTION 'Room already booked for this slot';
  END IF;

  RETURN NEW;
END $$;


--
-- Name: check_term_in_year(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_term_in_year() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE s date; e date;
BEGIN
  SELECT year_start, year_end INTO s, e
  FROM public.school_years WHERE school_year_id = NEW.school_year_id;
  IF NEW.start_date < s OR NEW.end_date > e THEN
    RAISE EXCEPTION 'Term dates must be within the school year';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: fill_assignment_denorm(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fill_assignment_denorm() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT c.teacher_id, c.class_group_id
    INTO NEW.teacher_id, NEW.class_group_id
  FROM public.courses c WHERE c.course_id = NEW.course_id;
  RETURN NEW;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: attendance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attendance (
    attendance_id bigint NOT NULL,
    student_id bigint NOT NULL,
    course_id bigint NOT NULL,
    date date NOT NULL,
    status public.attendance_status NOT NULL,
    reason_note text,
    recorded_by character varying(50),
    recorded_at timestamp with time zone DEFAULT now(),
    excused_by character varying(50),
    excused_at timestamp with time zone,
    deleted_at timestamp with time zone,
    slot_id bigint
);


--
-- Name: attendance_attendance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.attendance_attendance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: attendance_attendance_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.attendance_attendance_id_seq OWNED BY public.attendance.attendance_id;


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    audit_id bigint NOT NULL,
    entity_name text NOT NULL,
    entity_id bigint,
    action character varying(20) NOT NULL,
    payload jsonb,
    performed_by character varying(50),
    performed_at timestamp with time zone DEFAULT now()
);


--
-- Name: audit_logs_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_logs_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_logs_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_logs_audit_id_seq OWNED BY public.audit_logs.audit_id;


--
-- Name: buildings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.buildings (
    building_id bigint NOT NULL,
    name character varying(80) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    is_lab boolean DEFAULT false NOT NULL,
    is_auditorium boolean DEFAULT false NOT NULL,
    is_computer_room boolean DEFAULT false NOT NULL
);


--
-- Name: buildings_building_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.buildings_building_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: buildings_building_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.buildings_building_id_seq OWNED BY public.buildings.building_id;


--
-- Name: class_group_curriculum_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.class_group_curriculum_overrides (
    override_id bigint NOT NULL,
    class_group_id bigint NOT NULL,
    curriculum_item_id bigint NOT NULL,
    weekly_hours_override integer,
    double_session_override boolean,
    is_disabled boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: class_group_curriculum_overrides_override_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.class_group_curriculum_overrides_override_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: class_group_curriculum_overrides_override_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.class_group_curriculum_overrides_override_id_seq OWNED BY public.class_group_curriculum_overrides.override_id;


--
-- Name: class_group_fixed_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.class_group_fixed_locations (
    fixed_location_id bigint NOT NULL,
    grade_level smallint NOT NULL,
    section character varying(10) NOT NULL,
    classroom_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: class_group_fixed_locations_fixed_location_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.class_group_fixed_locations_fixed_location_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: class_group_fixed_locations_fixed_location_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.class_group_fixed_locations_fixed_location_id_seq OWNED BY public.class_group_fixed_locations.fixed_location_id;


--
-- Name: class_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.class_groups (
    class_group_id bigint NOT NULL,
    school_year_id bigint NOT NULL,
    grade_level smallint NOT NULL,
    section character varying(10) NOT NULL,
    classroom_id bigint,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT chk_cg_section_format CHECK (((section)::text ~ '^[0-9]{2}$'::text)),
    CONSTRAINT chk_class_groups_section_two_digits CHECK (((section)::text ~ '^[0-9]{2}$'::text)),
    CONSTRAINT class_groups_grade_level_check CHECK (((grade_level >= 1) AND (grade_level <= 11)))
);


--
-- Name: class_groups_class_group_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.class_groups_class_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: class_groups_class_group_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.class_groups_class_group_id_seq OWNED BY public.class_groups.class_group_id;


--
-- Name: classrooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.classrooms (
    classroom_id bigint NOT NULL,
    name character varying(80) NOT NULL,
    capacity integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    building_id bigint
);


--
-- Name: classrooms_classroom_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.classrooms_classroom_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: classrooms_classroom_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.classrooms_classroom_id_seq OWNED BY public.classrooms.classroom_id;


--
-- Name: course_instances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_instances (
    course_instance_id bigint NOT NULL,
    subject_id bigint NOT NULL,
    grade_level smallint NOT NULL,
    school_year_id bigint NOT NULL,
    weekly_hours integer DEFAULT 0 NOT NULL,
    course_code character varying(50) NOT NULL,
    course_name character varying(120) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    scope_type public.course_instance_scope DEFAULT 'GRADE'::public.course_instance_scope NOT NULL,
    class_group_id bigint,
    curriculum_item_id bigint,
    double_session_required boolean DEFAULT false NOT NULL,
    CONSTRAINT course_instances_grade_level_check CHECK (((grade_level >= 1) AND (grade_level <= 11))),
    CONSTRAINT course_instances_scope_class_group_ck CHECK ((((scope_type = 'GRADE'::public.course_instance_scope) AND (class_group_id IS NULL)) OR ((scope_type = 'CLASS_GROUP'::public.course_instance_scope) AND (class_group_id IS NOT NULL))))
);


--
-- Name: course_instances_course_instance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_instances_course_instance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_instances_course_instance_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_instances_course_instance_id_seq OWNED BY public.course_instances.course_instance_id;


--
-- Name: courses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.courses (
    course_id bigint NOT NULL,
    course_instance_id bigint NOT NULL,
    class_group_id bigint NOT NULL,
    teacher_id character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: courses_course_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.courses_course_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: courses_course_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.courses_course_id_seq OWNED BY public.courses.course_id;


--
-- Name: curricula; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.curricula (
    curriculum_id bigint NOT NULL,
    grade_level smallint NOT NULL,
    name character varying(120) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    track_name character varying(120),
    specialization_area_id bigint
);


--
-- Name: curricula_curriculum_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.curricula_curriculum_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: curricula_curriculum_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.curricula_curriculum_id_seq OWNED BY public.curricula.curriculum_id;


--
-- Name: curriculum_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.curriculum_items (
    curriculum_item_id bigint NOT NULL,
    curriculum_id bigint NOT NULL,
    subject_id bigint NOT NULL,
    weekly_hours integer DEFAULT 0 NOT NULL,
    double_session_required boolean DEFAULT false NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: curriculum_items_curriculum_item_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.curriculum_items_curriculum_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: curriculum_items_curriculum_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.curriculum_items_curriculum_item_id_seq OWNED BY public.curriculum_items.curriculum_item_id;


--
-- Name: disciplinary_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.disciplinary_records (
    disciplinary_id bigint NOT NULL,
    student_id bigint NOT NULL,
    date_happened date NOT NULL,
    category public.disciplinary_level NOT NULL,
    description text,
    recorded_by character varying(50),
    created_at timestamp with time zone DEFAULT now(),
    expires_at date,
    deleted_at timestamp with time zone
);


--
-- Name: disciplinary_records_disciplinary_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.disciplinary_records_disciplinary_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: disciplinary_records_disciplinary_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.disciplinary_records_disciplinary_id_seq OWNED BY public.disciplinary_records.disciplinary_id;


--
-- Name: enrollments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enrollments (
    enrollment_id bigint NOT NULL,
    student_id bigint NOT NULL,
    class_group_id bigint,
    school_year_id bigint NOT NULL,
    enrolled_at timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true,
    grade_level smallint NOT NULL
);


--
-- Name: enrollments_enrollment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.enrollments_enrollment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enrollments_enrollment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.enrollments_enrollment_id_seq OWNED BY public.enrollments.enrollment_id;


--
-- Name: grade_scheme_values; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grade_scheme_values (
    value_id bigint NOT NULL,
    scheme_id bigint NOT NULL,
    code character varying(10) NOT NULL,
    label character varying(50) NOT NULL,
    sort_order smallint NOT NULL,
    is_passing boolean NOT NULL
);


--
-- Name: grade_scheme_values_value_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.grade_scheme_values_value_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: grade_scheme_values_value_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.grade_scheme_values_value_id_seq OWNED BY public.grade_scheme_values.value_id;


--
-- Name: grade_schemes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grade_schemes (
    scheme_id bigint NOT NULL,
    name character varying(40) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: grade_schemes_scheme_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.grade_schemes_scheme_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: grade_schemes_scheme_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.grade_schemes_scheme_id_seq OWNED BY public.grade_schemes.scheme_id;


--
-- Name: grades; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.grades (
    grade_id bigint NOT NULL,
    student_id bigint NOT NULL,
    course_id bigint NOT NULL,
    term_id bigint NOT NULL,
    scheme_value_id bigint,
    recorded_by character varying(50),
    created_at timestamp with time zone DEFAULT now(),
    comment text,
    mark smallint DEFAULT 4 NOT NULL
);


--
-- Name: COLUMN grades.mark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.grades.mark IS 'Numeric mark domain: 5=S, 4=A, 3=B, 1=J. Values 2 and 0 are unused.';


--
-- Name: grades_grade_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.grades_grade_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: grades_grade_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.grades_grade_id_seq OWNED BY public.grades.grade_id;


--
-- Name: migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.migrations (
    id integer NOT NULL,
    "timestamp" bigint NOT NULL,
    name character varying NOT NULL
);


--
-- Name: migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.migrations_id_seq OWNED BY public.migrations.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    notification_id bigint NOT NULL,
    created_by character varying(50),
    created_at timestamp with time zone DEFAULT now(),
    title character varying(120) NOT NULL,
    message text,
    is_active boolean DEFAULT true NOT NULL,
    category character varying(40) DEFAULT 'general'::character varying NOT NULL,
    student_id bigint
);


--
-- Name: notifications_notification_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_notification_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_notification_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_notification_id_seq OWNED BY public.notifications.notification_id;


--
-- Name: planilla_sheets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.planilla_sheets (
    planilla_sheet_id bigint NOT NULL,
    school_year_id bigint NOT NULL,
    class_group_id bigint,
    grade_level smallint NOT NULL,
    section character varying(10) NOT NULL,
    group_code character varying(10) NOT NULL,
    source_sheet character varying(80) NOT NULL,
    source_file_name character varying(255),
    template_key character varying(80) DEFAULT 'iedrc-secondary-v1'::character varying NOT NULL,
    title character varying(150) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    columns jsonb DEFAULT '[]'::jsonb NOT NULL,
    rows jsonb DEFAULT '[]'::jsonb NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    imported_by character varying(50),
    imported_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    import_closed_at timestamp with time zone
);


--
-- Name: planilla_sheets_planilla_sheet_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.planilla_sheets_planilla_sheet_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: planilla_sheets_planilla_sheet_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.planilla_sheets_planilla_sheet_id_seq OWNED BY public.planilla_sheets.planilla_sheet_id;


--
-- Name: print_generation_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.print_generation_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: school_years; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.school_years (
    school_year_id bigint NOT NULL,
    name character varying(20) NOT NULL,
    year_start date NOT NULL,
    year_end date NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: school_years_school_year_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.school_years_school_year_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: school_years_school_year_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.school_years_school_year_id_seq OWNED BY public.school_years.school_year_id;


--
-- Name: students; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.students (
    student_id bigint NOT NULL,
    national_id character varying(50) NOT NULL,
    first_name character varying(80) NOT NULL,
    last_name character varying(80) NOT NULL,
    dob date,
    address text,
    guardian_name character varying(120),
    guardian_relationship character varying(60),
    guardian_phone character varying(50) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    gender character varying(20) DEFAULT 'No Binario'::character varying NOT NULL,
    CONSTRAINT chk_students_gender CHECK (((gender)::text = ANY ((ARRAY['Femenino'::character varying, 'Masculino'::character varying, 'No Binario'::character varying])::text[])))
);


--
-- Name: students_student_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.students_student_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: students_student_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.students_student_id_seq OWNED BY public.students.student_id;


--
-- Name: subject_areas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subject_areas (
    area_id bigint NOT NULL,
    name character varying(120) NOT NULL,
    code character varying(40),
    is_specialization boolean DEFAULT false NOT NULL
);


--
-- Name: subject_areas_area_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.subject_areas_area_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: subject_areas_area_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.subject_areas_area_id_seq OWNED BY public.subject_areas.area_id;


--
-- Name: subjects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subjects (
    subject_id bigint NOT NULL,
    area_id bigint NOT NULL,
    subject_code character varying(50) NOT NULL,
    name character varying(120) NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: subjects_subject_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.subjects_subject_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: subjects_subject_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.subjects_subject_id_seq OWNED BY public.subjects.subject_id;


--
-- Name: teacher_subjects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teacher_subjects (
    teacher_subject_id bigint NOT NULL,
    teacher_id character varying(50) NOT NULL,
    subject_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: teacher_subjects_teacher_subject_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.teacher_subjects_teacher_subject_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: teacher_subjects_teacher_subject_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.teacher_subjects_teacher_subject_id_seq OWNED BY public.teacher_subjects.teacher_subject_id;


--
-- Name: terms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terms (
    term_id bigint NOT NULL,
    school_year_id bigint NOT NULL,
    name character varying(20) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    sort_order smallint NOT NULL,
    is_final boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: terms_term_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.terms_term_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: terms_term_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.terms_term_id_seq OWNED BY public.terms.term_id;


--
-- Name: timetable_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timetable_assignments (
    assignment_id bigint NOT NULL,
    course_id bigint NOT NULL,
    slot_id bigint NOT NULL,
    classroom_id bigint,
    created_at timestamp with time zone DEFAULT now(),
    teacher_id character varying(50),
    class_group_id bigint
);


--
-- Name: timetable_assignments_assignment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.timetable_assignments_assignment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: timetable_assignments_assignment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.timetable_assignments_assignment_id_seq OWNED BY public.timetable_assignments.assignment_id;


--
-- Name: timetable_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.timetable_slots (
    slot_id bigint NOT NULL,
    day_of_week smallint NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    duration_minutes integer NOT NULL,
    division character varying(20) DEFAULT 'elementary'::character varying NOT NULL,
    CONSTRAINT chk_slot_time CHECK ((end_time > start_time)),
    CONSTRAINT chk_timetable_slots_division CHECK (((division)::text = ANY ((ARRAY['elementary'::character varying, 'secondary'::character varying, 'senior'::character varying])::text[]))),
    CONSTRAINT timetable_slots_check CHECK ((start_time < end_time)),
    CONSTRAINT timetable_slots_day_of_week_check CHECK (((day_of_week >= 1) AND (day_of_week <= 7)))
);


--
-- Name: timetable_slots_slot_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.timetable_slots_slot_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: timetable_slots_slot_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.timetable_slots_slot_id_seq OWNED BY public.timetable_slots.slot_id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    national_id character varying(50) NOT NULL,
    username character varying(80) NOT NULL,
    password_hash text NOT NULL,
    role public.user_role NOT NULL,
    first_name character varying(80),
    last_name character varying(80),
    email character varying(150),
    phone character varying(30),
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    must_change_password boolean DEFAULT false NOT NULL,
    temp_password_issued_at timestamp with time zone
);


--
-- Name: attendance attendance_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance ALTER COLUMN attendance_id SET DEFAULT nextval('public.attendance_attendance_id_seq'::regclass);


--
-- Name: audit_logs audit_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs ALTER COLUMN audit_id SET DEFAULT nextval('public.audit_logs_audit_id_seq'::regclass);


--
-- Name: buildings building_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buildings ALTER COLUMN building_id SET DEFAULT nextval('public.buildings_building_id_seq'::regclass);


--
-- Name: class_group_curriculum_overrides override_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_curriculum_overrides ALTER COLUMN override_id SET DEFAULT nextval('public.class_group_curriculum_overrides_override_id_seq'::regclass);


--
-- Name: class_group_fixed_locations fixed_location_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_fixed_locations ALTER COLUMN fixed_location_id SET DEFAULT nextval('public.class_group_fixed_locations_fixed_location_id_seq'::regclass);


--
-- Name: class_groups class_group_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_groups ALTER COLUMN class_group_id SET DEFAULT nextval('public.class_groups_class_group_id_seq'::regclass);


--
-- Name: classrooms classroom_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.classrooms ALTER COLUMN classroom_id SET DEFAULT nextval('public.classrooms_classroom_id_seq'::regclass);


--
-- Name: course_instances course_instance_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_instances ALTER COLUMN course_instance_id SET DEFAULT nextval('public.course_instances_course_instance_id_seq'::regclass);


--
-- Name: courses course_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses ALTER COLUMN course_id SET DEFAULT nextval('public.courses_course_id_seq'::regclass);


--
-- Name: curricula curriculum_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curricula ALTER COLUMN curriculum_id SET DEFAULT nextval('public.curricula_curriculum_id_seq'::regclass);


--
-- Name: curriculum_items curriculum_item_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum_items ALTER COLUMN curriculum_item_id SET DEFAULT nextval('public.curriculum_items_curriculum_item_id_seq'::regclass);


--
-- Name: disciplinary_records disciplinary_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disciplinary_records ALTER COLUMN disciplinary_id SET DEFAULT nextval('public.disciplinary_records_disciplinary_id_seq'::regclass);


--
-- Name: enrollments enrollment_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments ALTER COLUMN enrollment_id SET DEFAULT nextval('public.enrollments_enrollment_id_seq'::regclass);


--
-- Name: grade_scheme_values value_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_scheme_values ALTER COLUMN value_id SET DEFAULT nextval('public.grade_scheme_values_value_id_seq'::regclass);


--
-- Name: grade_schemes scheme_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_schemes ALTER COLUMN scheme_id SET DEFAULT nextval('public.grade_schemes_scheme_id_seq'::regclass);


--
-- Name: grades grade_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades ALTER COLUMN grade_id SET DEFAULT nextval('public.grades_grade_id_seq'::regclass);


--
-- Name: migrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migrations ALTER COLUMN id SET DEFAULT nextval('public.migrations_id_seq'::regclass);


--
-- Name: notifications notification_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN notification_id SET DEFAULT nextval('public.notifications_notification_id_seq'::regclass);


--
-- Name: planilla_sheets planilla_sheet_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.planilla_sheets ALTER COLUMN planilla_sheet_id SET DEFAULT nextval('public.planilla_sheets_planilla_sheet_id_seq'::regclass);


--
-- Name: school_years school_year_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.school_years ALTER COLUMN school_year_id SET DEFAULT nextval('public.school_years_school_year_id_seq'::regclass);


--
-- Name: students student_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.students ALTER COLUMN student_id SET DEFAULT nextval('public.students_student_id_seq'::regclass);


--
-- Name: subject_areas area_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subject_areas ALTER COLUMN area_id SET DEFAULT nextval('public.subject_areas_area_id_seq'::regclass);


--
-- Name: subjects subject_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subjects ALTER COLUMN subject_id SET DEFAULT nextval('public.subjects_subject_id_seq'::regclass);


--
-- Name: teacher_subjects teacher_subject_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teacher_subjects ALTER COLUMN teacher_subject_id SET DEFAULT nextval('public.teacher_subjects_teacher_subject_id_seq'::regclass);


--
-- Name: terms term_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms ALTER COLUMN term_id SET DEFAULT nextval('public.terms_term_id_seq'::regclass);


--
-- Name: timetable_assignments assignment_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_assignments ALTER COLUMN assignment_id SET DEFAULT nextval('public.timetable_assignments_assignment_id_seq'::regclass);


--
-- Name: timetable_slots slot_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_slots ALTER COLUMN slot_id SET DEFAULT nextval('public.timetable_slots_slot_id_seq'::regclass);


--
-- Data for Name: attendance; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.attendance (attendance_id, student_id, course_id, date, status, reason_note, recorded_by, recorded_at, excused_by, excused_at, deleted_at, slot_id) FROM stdin;
3	310	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.072358+01	\N	\N	\N	\N
6	289	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.074844+01	\N	\N	\N	\N
2	282	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.070094+01	\N	\N	\N	\N
5	233	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.069951+01	\N	\N	\N	\N
10	261	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.134877+01	\N	\N	\N	\N
12	240	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.136786+01	\N	\N	\N	\N
13	226	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.141141+01	\N	\N	\N	\N
14	254	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.142829+01	\N	\N	\N	\N
1	296	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.069254+01	\N	\N	\N	\N
7	268	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.076025+01	\N	\N	\N	\N
4	247	69	2026-03-17	AE	\N	950001	2026-03-17 11:51:35.073244+01	\N	\N	\N	\N
8	303	69	2026-03-17	A	\N	950001	2026-03-17 11:51:35.076446+01	\N	\N	\N	\N
9	317	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.076169+01	\N	\N	\N	\N
11	275	69	2026-03-17	P	\N	950001	2026-03-17 11:51:35.135857+01	\N	\N	\N	\N
15	93	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.830937+01	\N	\N	\N	\N
16	142	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.835337+01	\N	\N	\N	\N
17	219	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.836837+01	\N	\N	\N	\N
18	79	70	2026-03-09	AE	\N	950001	2026-03-17 11:55:09.837604+01	\N	\N	\N	\N
19	44	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.839436+01	\N	\N	\N	\N
20	184	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.841224+01	\N	\N	\N	\N
21	9	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.883865+01	\N	\N	\N	\N
22	170	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.886771+01	\N	\N	\N	\N
23	37	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.887167+01	\N	\N	\N	\N
25	30	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.887889+01	\N	\N	\N	\N
24	177	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.88724+01	\N	\N	\N	\N
26	149	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.887839+01	\N	\N	\N	\N
27	23	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.923657+01	\N	\N	\N	\N
28	163	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.923749+01	\N	\N	\N	\N
29	107	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.929391+01	\N	\N	\N	\N
30	128	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.931613+01	\N	\N	\N	\N
31	191	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.933574+01	\N	\N	\N	\N
32	51	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.93399+01	\N	\N	\N	\N
33	65	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.970586+01	\N	\N	\N	\N
34	205	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.972988+01	\N	\N	\N	\N
35	16	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.973752+01	\N	\N	\N	\N
36	156	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.97503+01	\N	\N	\N	\N
37	121	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.975629+01	\N	\N	\N	\N
38	100	70	2026-03-09	P	\N	950001	2026-03-17 11:55:09.976698+01	\N	\N	\N	\N
39	58	70	2026-03-09	P	\N	950001	2026-03-17 11:55:10.008494+01	\N	\N	\N	\N
40	135	70	2026-03-09	P	\N	950001	2026-03-17 11:55:10.008577+01	\N	\N	\N	\N
41	198	70	2026-03-09	P	\N	950001	2026-03-17 11:55:10.019346+01	\N	\N	\N	\N
42	72	70	2026-03-09	P	\N	950001	2026-03-17 11:55:10.020888+01	\N	\N	\N	\N
43	86	70	2026-03-09	P	\N	950001	2026-03-17 11:55:10.021547+01	\N	\N	\N	\N
44	212	70	2026-03-09	P	\N	950001	2026-03-17 11:55:10.021736+01	\N	\N	\N	\N
45	114	70	2026-03-09	P	\N	950001	2026-03-17 11:55:10.046887+01	\N	\N	\N	\N
48	345	68	2026-03-17	AE	\N	950001	2026-03-17 11:56:41.785526+01	\N	\N	\N	\N
47	324	68	2026-03-17	A	\N	950001	2026-03-17 11:56:41.784779+01	\N	\N	\N	\N
46	352	68	2026-03-17	P	\N	950001	2026-03-17 11:56:41.783935+01	\N	\N	\N	\N
54	303	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.053606+01	\N	\N	\N	\N
53	310	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.053388+01	\N	\N	\N	\N
50	282	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.038321+01	\N	\N	\N	\N
49	233	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.038388+01	\N	\N	\N	\N
52	289	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.050966+01	\N	\N	\N	\N
55	240	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.299609+01	\N	\N	\N	\N
59	275	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.303179+01	\N	\N	\N	\N
56	268	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.301884+01	\N	\N	\N	\N
60	296	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.303881+01	\N	\N	\N	\N
57	261	69	2026-03-24	A	\N	950001	2026-03-17 14:50:10.302601+01	\N	\N	\N	\N
58	247	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.303074+01	\N	\N	\N	\N
61	226	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.45739+01	\N	\N	\N	\N
62	254	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.457486+01	\N	\N	\N	\N
51	317	69	2026-03-24	P	\N	950001	2026-03-17 14:50:10.050345+01	\N	\N	\N	\N
\.


--
-- Data for Name: audit_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.audit_logs (audit_id, entity_name, entity_id, action, payload, performed_by, performed_at) FROM stdin;
\.


--
-- Data for Name: buildings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.buildings (building_id, name, created_at, is_lab, is_auditorium, is_computer_room) FROM stdin;
1	Building A	2026-02-28 20:26:25.045489+01	f	f	f
2	EdificioA	2026-03-09 20:05:08.884289+01	f	f	f
3	EdificioB	2026-03-09 20:05:08.884289+01	f	f	f
4	EdificioC	2026-03-09 20:05:08.884289+01	f	f	f
5	EdificioD	2026-03-09 20:05:08.884289+01	f	f	f
6	EdificioE	2026-03-09 20:05:08.884289+01	f	f	f
\.


--
-- Data for Name: class_group_curriculum_overrides; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.class_group_curriculum_overrides (override_id, class_group_id, curriculum_item_id, weekly_hours_override, double_session_override, is_disabled, created_at) FROM stdin;
\.


--
-- Data for Name: class_group_fixed_locations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.class_group_fixed_locations (fixed_location_id, grade_level, section, classroom_id, created_at) FROM stdin;
\.


--
-- Data for Name: class_groups; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.class_groups (class_group_id, school_year_id, grade_level, section, classroom_id, created_at) FROM stdin;
1	1	9	01	1	2026-03-04 23:20:24.119548+01
2	1	9	02	2	2026-03-14 16:04:09.95778+01
3	1	9	03	5	2026-03-14 16:17:26.45083+01
4	1	9	04	3	2026-03-14 16:19:12.716868+01
5	1	9	05	7	2026-03-14 16:19:26.735771+01
\.


--
-- Data for Name: classrooms; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.classrooms (classroom_id, name, capacity, created_at, building_id) FROM stdin;
1	BuildingA_Aula01	34	2026-03-04 16:48:06.984524+01	1
2	BuildingA_Aula02	34	2026-03-04 16:48:22.396593+01	1
3	EdificioA_Aula01	25	2026-03-09 20:05:08.884289+01	2
4	EdificioA_Aula02	25	2026-03-09 20:05:08.884289+01	2
5	EdificioA_Aula03	25	2026-03-09 20:05:08.884289+01	2
6	EdificioA_Aula04	25	2026-03-09 20:05:08.884289+01	2
7	EdificioA_Aula05	25	2026-03-09 20:05:08.884289+01	2
8	EdificioA_Aula06	25	2026-03-09 20:05:08.884289+01	2
9	EdificioA_Aula07	25	2026-03-09 20:05:08.884289+01	2
10	EdificioA_Aula08	25	2026-03-09 20:05:08.884289+01	2
11	EdificioA_Aula09	25	2026-03-09 20:05:08.884289+01	2
12	EdificioA_Aula10	25	2026-03-09 20:05:08.884289+01	2
13	EdificioB_Aula01	25	2026-03-09 20:05:08.884289+01	3
14	EdificioB_Aula02	25	2026-03-09 20:05:08.884289+01	3
15	EdificioB_Aula03	25	2026-03-09 20:05:08.884289+01	3
16	EdificioB_Aula04	25	2026-03-09 20:05:08.884289+01	3
17	EdificioB_Aula05	25	2026-03-09 20:05:08.884289+01	3
18	EdificioB_Aula06	25	2026-03-09 20:05:08.884289+01	3
19	EdificioB_Aula07	25	2026-03-09 20:05:08.884289+01	3
20	EdificioB_Aula08	25	2026-03-09 20:05:08.884289+01	3
21	EdificioB_Aula09	25	2026-03-09 20:05:08.884289+01	3
22	EdificioB_Aula10	25	2026-03-09 20:05:08.884289+01	3
23	EdificioC_Aula01	25	2026-03-09 20:05:08.884289+01	4
24	EdificioC_Aula02	25	2026-03-09 20:05:08.884289+01	4
25	EdificioC_Aula03	25	2026-03-09 20:05:08.884289+01	4
26	EdificioC_Aula04	25	2026-03-09 20:05:08.884289+01	4
27	EdificioC_Aula05	25	2026-03-09 20:05:08.884289+01	4
28	EdificioC_Aula06	25	2026-03-09 20:05:08.884289+01	4
29	EdificioC_Aula07	25	2026-03-09 20:05:08.884289+01	4
30	EdificioC_Aula08	25	2026-03-09 20:05:08.884289+01	4
31	EdificioC_Aula09	25	2026-03-09 20:05:08.884289+01	4
32	EdificioC_Aula10	25	2026-03-09 20:05:08.884289+01	4
33	EdificioD_Aula01	25	2026-03-09 20:05:08.884289+01	5
34	EdificioD_Aula02	25	2026-03-09 20:05:08.884289+01	5
35	EdificioD_Aula03	25	2026-03-09 20:05:08.884289+01	5
36	EdificioD_Aula04	25	2026-03-09 20:05:08.884289+01	5
37	EdificioD_Aula05	25	2026-03-09 20:05:08.884289+01	5
38	EdificioD_Aula06	25	2026-03-09 20:05:08.884289+01	5
39	EdificioD_Aula07	25	2026-03-09 20:05:08.884289+01	5
40	EdificioD_Aula08	25	2026-03-09 20:05:08.884289+01	5
41	EdificioD_Aula09	25	2026-03-09 20:05:08.884289+01	5
42	EdificioD_Aula10	25	2026-03-09 20:05:08.884289+01	5
43	EdificioE_Aula01	25	2026-03-09 20:05:08.884289+01	6
44	EdificioE_Aula02	25	2026-03-09 20:05:08.884289+01	6
45	EdificioE_Aula03	25	2026-03-09 20:05:08.884289+01	6
46	EdificioE_Aula04	25	2026-03-09 20:05:08.884289+01	6
47	EdificioE_Aula05	25	2026-03-09 20:05:08.884289+01	6
48	EdificioE_Aula06	25	2026-03-09 20:05:08.884289+01	6
49	EdificioE_Aula07	25	2026-03-09 20:05:08.884289+01	6
50	EdificioE_Aula08	25	2026-03-09 20:05:08.884289+01	6
51	EdificioE_Aula09	25	2026-03-09 20:05:08.884289+01	6
52	EdificioE_Aula10	25	2026-03-09 20:05:08.884289+01	6
\.


--
-- Data for Name: course_instances; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.course_instances (course_instance_id, subject_id, grade_level, school_year_id, weekly_hours, course_code, course_name, description, is_active, created_at, scope_type, class_group_id, curriculum_item_id, double_session_required) FROM stdin;
1	3	9	1	3	CN_N-9-Y2026	Naturales Grado 9	\N	t	2026-03-14 16:38:05.454573+01	GRADE	\N	\N	f
2	5	9	1	1	CS_E-9-Y2026	Etica Grado 9	\N	t	2026-03-14 18:48:05.561646+01	GRADE	\N	\N	f
3	6	9	1	1	CS_ER-9-Y2026	Educacion Religiosa Grado 9	\N	t	2026-03-14 18:48:05.62849+01	GRADE	\N	\N	f
4	4	9	1	3	CS_S-9-Y2026	Sociales Grado 9	\N	t	2026-03-14 18:48:05.684574+01	GRADE	\N	\N	f
5	12	9	1	1	EA_M-9-Y2026	Musica Grado 9	\N	t	2026-03-14 18:48:05.741454+01	GRADE	\N	\N	f
6	18	9	1	1	EE_E-9-Y2026	Emprendimiento Grado 9	\N	t	2026-03-14 18:48:05.794854+01	GRADE	\N	\N	f
7	10	9	1	2	EF_EF-9-Y2026	Educacion Fisica Grado 9	\N	t	2026-03-14 18:48:05.861304+01	GRADE	\N	\N	f
8	7	9	1	4	HUM_E-9-Y2026	Espanol Grado 9	\N	t	2026-03-14 18:48:05.926992+01	GRADE	\N	\N	f
9	56	9	1	1	HUM_EM-9-Y2026	Emprendimiento Grado 9	\N	t	2026-03-14 18:48:05.984173+01	GRADE	\N	\N	f
10	2	9	1	3	HUM_I-9-Y2026	Ingles Grado 9	\N	t	2026-03-14 18:48:06.045879+01	GRADE	\N	\N	f
11	9	9	1	1	HUM_LC-9-Y2026	Lectura Critica Grado 9	\N	t	2026-03-14 18:48:06.156484+01	GRADE	\N	\N	f
12	11	9	1	5	MAT_M-9-Y2026	Matematicas Grado 9	\N	t	2026-03-14 18:48:06.237989+01	GRADE	\N	\N	f
13	17	9	1	1	TEI_I-9-Y2026	Informatica Grado 9	\N	t	2026-03-14 18:48:06.286837+01	GRADE	\N	\N	f
14	54	9	1	2	TEI_P-9-Y2026	Programacion Grado 9	\N	t	2026-03-14 18:48:06.343108+01	GRADE	\N	\N	f
15	16	9	1	2	TEI_T-9-Y2026	Tecnologia Grado 9	\N	t	2026-03-14 18:48:06.407055+01	GRADE	\N	\N	f
\.


--
-- Data for Name: courses; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.courses (course_id, course_instance_id, class_group_id, teacher_id, created_at) FROM stdin;
1	1	1	000015	2026-03-14 18:48:05.392823+01
2	1	2	000032	2026-03-14 18:48:05.506383+01
3	1	3	000015	2026-03-14 18:48:05.522267+01
4	1	4	000013	2026-03-14 18:48:05.539114+01
5	1	5	000020	2026-03-14 18:48:05.54987+01
6	2	1	000010	2026-03-14 18:48:05.573966+01
7	2	2	00033	2026-03-14 18:48:05.584019+01
8	2	3	000011	2026-03-14 18:48:05.595826+01
9	2	4	000011	2026-03-14 18:48:05.60826+01
10	2	5	00033	2026-03-14 18:48:05.619016+01
11	3	1	000036	2026-03-14 18:48:05.637793+01
12	3	2	000011	2026-03-14 18:48:05.647103+01
13	3	3	00033	2026-03-14 18:48:05.656049+01
14	3	4	000036	2026-03-14 18:48:05.665597+01
15	3	5	000011	2026-03-14 18:48:05.675117+01
16	4	1	00033	2026-03-14 18:48:05.693183+01
17	4	2	00033	2026-03-14 18:48:05.702923+01
18	4	3	000031	2026-03-14 18:48:05.71192+01
19	4	4	000031	2026-03-14 18:48:05.721052+01
20	4	5	00033	2026-03-14 18:48:05.730917+01
21	5	1	000016	2026-03-14 18:48:05.750666+01
22	5	2	000016	2026-03-14 18:48:05.759902+01
23	5	3	000016	2026-03-14 18:48:05.768437+01
24	5	4	000008	2026-03-14 18:48:05.777545+01
25	5	5	000016	2026-03-14 18:48:05.786317+01
26	6	1	000021	2026-03-14 18:48:05.805756+01
27	6	2	000021	2026-03-14 18:48:05.814768+01
28	6	3	000012	2026-03-14 18:48:05.823126+01
29	6	4	000012	2026-03-14 18:48:05.833309+01
30	6	5	000021	2026-03-14 18:48:05.849716+01
31	7	1	000003	2026-03-14 18:48:05.871168+01
32	7	2	000002	2026-03-14 18:48:05.882993+01
33	7	3	000004	2026-03-14 18:48:05.89413+01
34	7	4	000002	2026-03-14 18:48:05.905082+01
35	7	5	000003	2026-03-14 18:48:05.916615+01
36	8	1	000005	2026-03-14 18:48:05.93672+01
37	8	2	000021	2026-03-14 18:48:05.947309+01
38	8	3	000027	2026-03-14 18:48:05.957399+01
39	8	4	000005	2026-03-14 18:48:05.966568+01
40	8	5	000017	2026-03-14 18:48:05.976011+01
41	9	1	000009	2026-03-14 18:48:05.994257+01
42	9	2	000009	2026-03-14 18:48:06.005267+01
43	9	3	000009	2026-03-14 18:48:06.015128+01
44	9	4	000009	2026-03-14 18:48:06.025621+01
45	9	5	000009	2026-03-14 18:48:06.034409+01
46	10	1	000037	2026-03-14 18:48:06.055299+01
47	10	2	000007	2026-03-14 18:48:06.066918+01
48	10	3	000036	2026-03-14 18:48:06.078384+01
49	10	4	000018	2026-03-14 18:48:06.08868+01
50	10	5	000005	2026-03-14 18:48:06.143868+01
51	11	1	000021	2026-03-14 18:48:06.165983+01
52	11	2	000007	2026-03-14 18:48:06.175436+01
53	11	3	000030	2026-03-14 18:48:06.212272+01
54	11	4	000021	2026-03-14 18:48:06.222072+01
55	11	5	000027	2026-03-14 18:48:06.23015+01
56	12	1	000034	2026-03-14 18:48:06.245116+01
57	12	2	000034	2026-03-14 18:48:06.253549+01
58	12	3	000013	2026-03-14 18:48:06.262385+01
59	12	4	000035	2026-03-14 18:48:06.270365+01
60	12	5	000034	2026-03-14 18:48:06.278502+01
61	13	1	000038	2026-03-14 18:48:06.293431+01
62	13	2	000027	2026-03-14 18:48:06.304022+01
63	13	3	000038	2026-03-14 18:48:06.314011+01
64	13	4	000027	2026-03-14 18:48:06.323887+01
65	13	5	000024	2026-03-14 18:48:06.33356+01
66	14	1	950001	2026-03-14 18:48:06.351794+01
67	14	2	950001	2026-03-14 18:48:06.361682+01
68	14	3	950001	2026-03-14 18:48:06.381526+01
69	14	4	950001	2026-03-14 18:48:06.389235+01
70	14	5	950001	2026-03-14 18:48:06.398017+01
71	15	1	000038	2026-03-14 18:48:06.416381+01
72	15	2	000006	2026-03-14 18:48:06.425849+01
73	15	3	000028	2026-03-14 18:48:06.434608+01
74	15	4	000028	2026-03-14 18:48:06.443695+01
75	15	5	000024	2026-03-14 18:48:06.452332+01
\.


--
-- Data for Name: curricula; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.curricula (curriculum_id, grade_level, name, is_active, created_at, track_name, specialization_area_id) FROM stdin;
1	6	Currículo grado 6	t	2026-02-17 22:52:28.427492+01	\N	\N
2	7	Currículo grado 7	t	2026-02-17 22:52:56.544389+01	\N	\N
3	8	Currículo grado 8	t	2026-02-24 22:27:10.798123+01	\N	\N
4	9	Currículo grado 9	t	2026-02-24 23:42:54.337306+01	\N	\N
5	10	Idustrial 10	t	2026-02-28 11:23:16.700246+01	Idustrial	11
6	11	Idustrial 11	t	2026-02-28 11:23:16.700246+01	Idustrial	11
9	10	Mecatronica 10	t	2026-02-28 11:25:12.3855+01	Mecatronica	10
10	11	Mecatronica 11	t	2026-02-28 11:25:12.3855+01	Mecatronica	10
7	10	Deportivo 10	t	2026-02-28 11:24:27.983338+01	Deportivo	9
8	11	Deportivo 11	t	2026-02-28 11:24:27.983338+01	Deportivo	9
\.


--
-- Data for Name: curriculum_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.curriculum_items (curriculum_item_id, curriculum_id, subject_id, weekly_hours, double_session_required, notes, created_at) FROM stdin;
2	1	1	1	f	\N	2026-02-17 22:52:28.427492+01
4	2	1	1	f	\N	2026-02-17 22:52:56.544389+01
5	1	4	4	f	\N	2026-02-24 22:13:02.899218+01
6	1	7	4	f	\N	2026-02-24 22:15:51.43268+01
7	1	2	3	f	\N	2026-02-24 22:15:51.435015+01
9	1	11	4	f	\N	2026-02-24 22:15:51.43519+01
8	1	16	2	t	\N	2026-02-24 22:15:51.435111+01
10	1	3	3	f	\N	2026-02-24 22:15:51.436705+01
11	1	6	1	f	\N	2026-02-24 22:15:51.436802+01
12	1	5	1	f	\N	2026-02-24 22:15:51.436854+01
13	1	13	1	f	\N	2026-02-24 22:15:51.448427+01
14	1	9	1	f	\N	2026-02-24 22:15:51.449507+01
15	1	17	2	t	\N	2026-02-24 22:15:51.451068+01
16	2	6	1	f	\N	2026-02-24 22:20:26.332825+01
17	2	4	4	f	\N	2026-02-24 22:20:26.332897+01
18	2	13	1	f	\N	2026-02-24 22:20:26.335342+01
19	2	17	2	t	\N	2026-02-24 22:20:26.336878+01
20	2	5	1	f	\N	2026-02-24 22:20:26.336955+01
21	2	12	1	f	\N	2026-02-24 22:20:26.337015+01
22	2	3	3	f	\N	2026-02-24 22:20:26.337162+01
23	2	16	2	t	\N	2026-02-24 22:20:26.337097+01
3	2	2	3	f	\N	2026-02-17 22:52:56.544389+01
24	2	11	4	f	\N	2026-02-24 22:20:26.349782+01
25	2	7	4	f	\N	2026-02-24 22:20:26.350848+01
26	2	10	3	t	\N	2026-02-24 22:20:26.351017+01
27	3	11	4	f	\N	2026-02-24 22:27:10.798123+01
28	3	7	4	f	\N	2026-02-24 22:27:10.798123+01
29	3	2	4	f	\N	2026-02-24 22:27:10.798123+01
30	3	3	4	f	\N	2026-02-24 22:27:10.798123+01
31	3	17	2	t	\N	2026-02-24 22:27:10.798123+01
32	3	4	3	f	\N	2026-02-24 22:27:10.798123+01
33	3	6	1	f	\N	2026-02-24 22:27:10.798123+01
34	3	13	1	f	\N	2026-02-24 22:27:10.798123+01
35	3	10	3	t	\N	2026-02-24 22:27:10.798123+01
36	3	16	2	t	\N	2026-02-24 22:27:10.798123+01
37	3	5	1	f	\N	2026-02-24 22:27:10.798123+01
38	3	1	1	f	\N	2026-02-24 22:32:02.365248+01
39	1	10	2	t	\N	2026-02-24 22:33:13.966234+01
40	1	12	1	f	\N	2026-02-24 22:33:38.278075+01
41	4	7	4	f	\N	2026-02-24 23:42:54.337306+01
42	4	11	5	f	\N	2026-02-24 23:42:54.337306+01
43	4	5	1	f	\N	2026-02-24 23:42:54.337306+01
44	4	6	1	f	\N	2026-02-24 23:42:54.337306+01
45	4	12	1	f	\N	2026-02-24 23:42:54.337306+01
46	4	18	1	f	\N	2026-02-24 23:42:54.337306+01
47	4	16	2	t	\N	2026-02-24 23:42:54.337306+01
48	4	4	3	f	\N	2026-02-24 23:42:54.337306+01
49	4	10	2	t	\N	2026-02-24 23:42:54.337306+01
51	4	2	3	f	\N	2026-02-24 23:42:54.337306+01
52	4	9	1	f	\N	2026-02-24 23:42:54.337306+01
54	4	17	1	f	\N	2026-02-24 23:42:54.337306+01
55	4	3	3	f	\N	2026-02-24 23:43:36.462411+01
58	7	24	3	f	\N	2026-02-28 11:24:27.983338+01
60	9	35	2	t	\N	2026-02-28 11:25:12.3855+01
62	4	54	2	f	\N	2026-02-28 12:04:13.100605+01
63	4	56	1	f	\N	2026-02-28 12:09:04.855194+01
64	7	22	1	f	\N	2026-02-28 12:25:34.991774+01
65	7	12	1	f	\N	2026-02-28 12:25:34.991801+01
67	7	10	2	f	\N	2026-02-28 12:25:34.991761+01
68	7	23	1	f	\N	2026-02-28 12:25:34.993107+01
69	7	20	2	f	\N	2026-02-28 12:25:34.993227+01
70	7	14	3	f	\N	2026-02-28 12:25:34.993416+01
72	7	7	3	f	\N	2026-02-28 12:25:34.993565+01
73	7	25	1	f	\N	2026-02-28 13:25:33.015148+01
74	7	15	2	f	\N	2026-02-28 13:25:33.015362+01
75	7	52	1	f	\N	2026-02-28 13:25:33.015441+01
76	7	27	3	t	\N	2026-02-28 13:25:33.017343+01
77	7	26	3	f	\N	2026-02-28 13:25:33.019583+01
78	7	11	3	f	\N	2026-02-28 13:25:33.027576+01
79	7	4	1	f	\N	2026-02-28 13:25:33.027805+01
80	7	31	2	f	\N	2026-02-28 13:25:33.036848+01
81	7	28	1	f	\N	2026-02-28 13:25:33.036923+01
82	7	2	2	f	\N	2026-02-28 13:25:33.040453+01
83	7	30	1	f	\N	2026-02-28 13:25:33.042695+01
84	7	5	1	f	\N	2026-02-28 13:25:33.045965+01
85	7	17	1	f	\N	2026-02-28 13:25:33.05077+01
87	7	29	1	f	\N	2026-02-28 13:25:33.05471+01
86	7	6	1	f	\N	2026-02-28 13:25:33.051136+01
88	8	12	1	f	\N	2026-02-28 13:33:44.473659+01
89	8	17	1	f	\N	2026-02-28 13:33:44.47378+01
93	8	7	3	f	\N	2026-02-28 13:33:44.475375+01
90	8	29	1	f	\N	2026-02-28 13:33:44.474199+01
91	8	11	3	f	\N	2026-02-28 13:33:44.474585+01
92	8	2	2	f	\N	2026-02-28 13:33:44.475311+01
59	8	24	3	t	\N	2026-02-28 11:24:27.983338+01
94	8	20	2	f	\N	2026-02-28 13:33:44.476925+01
95	8	52	1	f	\N	2026-02-28 13:33:44.477746+01
96	8	30	2	t	\N	2026-02-28 13:33:44.496993+01
97	8	14	3	f	\N	2026-02-28 13:33:44.497062+01
98	8	15	2	f	\N	2026-02-28 13:33:44.497116+01
99	8	27	3	f	\N	2026-02-28 13:33:44.497176+01
100	8	10	2	t	\N	2026-02-28 13:33:44.498539+01
101	8	22	1	f	\N	2026-02-28 13:33:44.500214+01
102	8	4	1	f	\N	2026-02-28 13:33:44.501965+01
103	8	6	1	f	\N	2026-02-28 13:33:44.504436+01
104	8	26	3	t	\N	2026-02-28 13:33:44.506962+01
105	8	5	1	f	\N	2026-02-28 13:33:44.513455+01
106	8	23	1	f	\N	2026-02-28 13:33:44.514422+01
107	8	25	1	f	\N	2026-02-28 13:33:44.515191+01
108	8	28	1	f	\N	2026-02-28 13:33:44.516665+01
109	8	31	1	f	\N	2026-02-28 13:33:44.516947+01
110	5	11	3	f	\N	2026-02-28 13:42:33.097483+01
111	5	17	1	f	\N	2026-02-28 13:42:33.098157+01
112	5	14	3	f	\N	2026-02-28 13:42:33.098163+01
113	5	13	1	f	\N	2026-02-28 13:42:33.097578+01
114	5	7	3	f	\N	2026-02-28 13:42:33.099376+01
115	5	43	4	t	\N	2026-02-28 13:42:33.101679+01
116	5	22	1	f	\N	2026-02-28 13:42:33.113995+01
117	5	4	1	f	\N	2026-02-28 13:42:33.114471+01
118	5	44	3	t	\N	2026-02-28 13:42:33.117057+01
119	5	2	3	f	\N	2026-02-28 13:42:33.117106+01
120	5	15	2	f	\N	2026-02-28 13:42:33.118905+01
121	5	5	1	f	\N	2026-02-28 13:42:33.118801+01
122	5	20	2	f	\N	2026-02-28 13:42:33.122637+01
123	5	6	1	f	\N	2026-02-28 13:42:33.124478+01
124	5	10	1	f	\N	2026-02-28 13:42:33.125655+01
125	5	46	2	f	\N	2026-02-28 13:42:33.132466+01
126	5	45	2	f	\N	2026-02-28 13:42:33.133859+01
130	5	50	1	f	\N	2026-02-28 13:42:33.138853+01
131	5	49	1	f	\N	2026-02-28 13:42:33.138945+01
127	5	47	2	f	\N	2026-02-28 13:42:33.134827+01
128	5	48	1	f	\N	2026-02-28 13:42:33.136891+01
129	5	52	1	f	\N	2026-02-28 13:42:33.137509+01
133	6	7	3	f	\N	2026-02-28 13:52:10.468269+01
134	6	50	1	f	\N	2026-02-28 13:52:10.467866+01
135	6	15	2	f	\N	2026-02-28 13:52:10.467882+01
132	6	17	1	f	\N	2026-02-28 13:52:10.467724+01
136	6	2	3	f	\N	2026-02-28 13:52:10.469344+01
137	6	51	2	t	\N	2026-02-28 13:52:10.469896+01
138	6	45	2	f	\N	2026-02-28 13:52:10.470946+01
139	6	11	3	f	\N	2026-02-28 13:52:10.475696+01
140	6	14	3	f	\N	2026-02-28 13:52:10.487154+01
141	6	10	1	f	\N	2026-02-28 13:52:10.488954+01
142	6	20	2	f	\N	2026-02-28 13:52:10.491381+01
143	6	4	1	f	\N	2026-02-28 13:52:10.493223+01
144	6	6	1	f	\N	2026-02-28 13:52:10.495214+01
145	6	47	2	t	\N	2026-02-28 13:52:10.496407+01
146	6	43	2	t	\N	2026-02-28 13:52:10.497762+01
147	6	5	1	f	\N	2026-02-28 13:52:10.499787+01
148	6	22	1	f	\N	2026-02-28 13:52:10.501199+01
149	6	49	1	f	\N	2026-02-28 13:52:10.507027+01
150	6	48	1	f	\N	2026-02-28 13:52:10.509648+01
151	6	13	1	f	\N	2026-02-28 13:52:10.509702+01
152	6	44	3	f	\N	2026-02-28 13:52:10.512581+01
153	6	46	2	t	\N	2026-02-28 13:52:10.51344+01
154	6	52	1	f	\N	2026-02-28 13:52:10.513545+01
156	9	15	2	f	\N	2026-02-28 13:57:27.810268+01
157	9	32	2	f	\N	2026-02-28 13:57:27.810188+01
155	9	22	1	f	\N	2026-02-28 13:57:27.809805+01
158	9	52	1	f	\N	2026-02-28 13:57:27.810231+01
159	9	33	2	f	\N	2026-02-28 13:57:27.811571+01
160	9	6	1	f	\N	2026-02-28 13:57:27.811461+01
161	9	11	3	f	\N	2026-02-28 13:57:27.811514+01
162	9	17	1	f	\N	2026-02-28 13:57:27.812588+01
163	9	23	1	f	\N	2026-02-28 13:57:27.817464+01
164	9	10	1	f	\N	2026-02-28 13:57:27.829139+01
165	9	7	3	f	\N	2026-02-28 13:57:27.830847+01
166	9	34	2	f	\N	2026-02-28 13:57:27.834032+01
167	9	13	1	f	\N	2026-02-28 13:57:27.837512+01
168	9	55	2	t	\N	2026-02-28 13:57:27.838768+01
169	9	20	2	f	\N	2026-02-28 13:57:27.840671+01
170	9	37	3	t	\N	2026-02-28 13:57:27.844606+01
171	9	14	3	f	\N	2026-02-28 13:57:27.848491+01
172	9	38	1	f	\N	2026-02-28 13:57:27.849668+01
173	9	39	2	t	\N	2026-02-28 13:57:27.851359+01
174	9	4	1	f	\N	2026-02-28 13:57:27.853392+01
175	9	5	1	f	\N	2026-02-28 13:57:27.853301+01
176	9	2	2	f	\N	2026-02-28 14:04:48.948954+01
177	10	32	2	t	\N	2026-02-28 14:08:44.205297+01
178	10	14	3	f	\N	2026-02-28 14:08:44.205372+01
179	10	7	3	f	\N	2026-02-28 14:08:44.207851+01
180	10	15	2	f	\N	2026-02-28 14:08:44.207907+01
181	10	6	1	f	\N	2026-02-28 14:08:44.208527+01
182	10	40	2	t	\N	2026-02-28 14:08:44.209776+01
183	10	41	2	f	\N	2026-02-28 14:08:44.210032+01
184	10	38	1	f	\N	2026-02-28 14:08:44.211837+01
185	10	2	2	f	\N	2026-02-28 14:08:44.226286+01
186	10	20	2	f	\N	2026-02-28 14:08:44.228177+01
187	10	22	1	f	\N	2026-02-28 14:08:44.229828+01
188	10	5	1	f	\N	2026-02-28 14:08:44.231654+01
189	10	10	1	f	\N	2026-02-28 14:08:44.233659+01
190	10	11	3	f	\N	2026-02-28 14:08:44.235797+01
191	10	55	2	t	\N	2026-02-28 14:08:44.237578+01
192	10	52	1	f	\N	2026-02-28 14:08:44.239652+01
193	10	13	1	f	\N	2026-02-28 14:08:44.242462+01
194	10	23	1	f	\N	2026-02-28 14:08:44.246016+01
195	10	33	2	t	\N	2026-02-28 14:08:44.248381+01
196	10	4	1	f	\N	2026-02-28 14:08:44.248578+01
197	10	34	2	t	\N	2026-02-28 14:08:44.249794+01
198	10	17	1	f	\N	2026-02-28 14:08:44.252644+01
199	10	37	3	t	\N	2026-02-28 14:08:44.253393+01
\.


--
-- Data for Name: disciplinary_records; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.disciplinary_records (disciplinary_id, student_id, date_happened, category, description, recorded_by, created_at, expires_at, deleted_at) FROM stdin;
\.


--
-- Data for Name: enrollments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.enrollments (enrollment_id, student_id, class_group_id, school_year_id, enrolled_at, active, grade_level) FROM stdin;
1	1	\N	1	2026-02-28 18:13:34.674668+01	t	6
2	2	1	1	2026-03-04 16:49:19.176733+01	t	9
3	3	\N	1	2026-03-09 18:44:46.535027+01	t	10
4	4	\N	1	2026-03-09 19:47:00.911039+01	t	7
5	5	\N	1	2026-03-09 20:02:55.916684+01	t	5
6	6	\N	1	2026-03-09 20:02:55.916684+01	t	6
7	7	\N	1	2026-03-09 20:02:55.916684+01	t	7
8	8	\N	1	2026-03-09 20:02:55.916684+01	t	8
10	10	\N	1	2026-03-09 20:02:55.916684+01	t	10
11	11	\N	1	2026-03-09 20:02:55.916684+01	t	11
12	12	\N	1	2026-03-09 20:02:55.916684+01	t	5
13	13	\N	1	2026-03-09 20:02:55.916684+01	t	6
14	14	\N	1	2026-03-09 20:02:55.916684+01	t	7
15	15	\N	1	2026-03-09 20:02:55.916684+01	t	8
17	17	\N	1	2026-03-09 20:02:55.916684+01	t	10
18	18	\N	1	2026-03-09 20:02:55.916684+01	t	11
19	19	\N	1	2026-03-09 20:02:55.916684+01	t	5
20	20	\N	1	2026-03-09 20:02:55.916684+01	t	6
21	21	\N	1	2026-03-09 20:02:55.916684+01	t	7
22	22	\N	1	2026-03-09 20:02:55.916684+01	t	8
24	24	\N	1	2026-03-09 20:02:55.916684+01	t	10
25	25	\N	1	2026-03-09 20:02:55.916684+01	t	11
26	26	\N	1	2026-03-09 20:02:55.916684+01	t	5
27	27	\N	1	2026-03-09 20:02:55.916684+01	t	6
28	28	\N	1	2026-03-09 20:02:55.916684+01	t	7
29	29	\N	1	2026-03-09 20:02:55.916684+01	t	8
31	31	\N	1	2026-03-09 20:02:55.916684+01	t	10
32	32	\N	1	2026-03-09 20:02:55.916684+01	t	11
33	33	\N	1	2026-03-09 20:02:55.916684+01	t	5
34	34	\N	1	2026-03-09 20:02:55.916684+01	t	6
35	35	\N	1	2026-03-09 20:02:55.916684+01	t	7
36	36	\N	1	2026-03-09 20:02:55.916684+01	t	8
38	38	\N	1	2026-03-09 20:02:55.916684+01	t	10
39	39	\N	1	2026-03-09 20:02:55.916684+01	t	11
40	40	\N	1	2026-03-09 20:02:55.916684+01	t	5
41	41	\N	1	2026-03-09 20:02:55.916684+01	t	6
42	42	\N	1	2026-03-09 20:02:55.916684+01	t	7
43	43	\N	1	2026-03-09 20:02:55.916684+01	t	8
45	45	\N	1	2026-03-09 20:02:55.916684+01	t	10
46	46	\N	1	2026-03-09 20:02:55.916684+01	t	11
47	47	\N	1	2026-03-09 20:02:55.916684+01	t	5
48	48	\N	1	2026-03-09 20:02:55.916684+01	t	6
49	49	\N	1	2026-03-09 20:02:55.916684+01	t	7
50	50	\N	1	2026-03-09 20:02:55.916684+01	t	8
52	52	\N	1	2026-03-09 20:02:55.916684+01	t	10
53	53	\N	1	2026-03-09 20:02:55.916684+01	t	11
54	54	\N	1	2026-03-09 20:02:55.916684+01	t	5
55	55	\N	1	2026-03-09 20:02:55.916684+01	t	6
56	56	\N	1	2026-03-09 20:02:55.916684+01	t	7
57	57	\N	1	2026-03-09 20:02:55.916684+01	t	8
59	59	\N	1	2026-03-09 20:02:55.916684+01	t	10
60	60	\N	1	2026-03-09 20:02:55.916684+01	t	11
61	61	\N	1	2026-03-09 20:02:55.916684+01	t	5
62	62	\N	1	2026-03-09 20:02:55.916684+01	t	6
63	63	\N	1	2026-03-09 20:02:55.916684+01	t	7
64	64	\N	1	2026-03-09 20:02:55.916684+01	t	8
66	66	\N	1	2026-03-09 20:02:55.916684+01	t	10
67	67	\N	1	2026-03-09 20:02:55.916684+01	t	11
68	68	\N	1	2026-03-09 20:02:55.916684+01	t	5
69	69	\N	1	2026-03-09 20:02:55.916684+01	t	6
70	70	\N	1	2026-03-09 20:02:55.916684+01	t	7
71	71	\N	1	2026-03-09 20:02:55.916684+01	t	8
73	73	\N	1	2026-03-09 20:02:55.916684+01	t	10
74	74	\N	1	2026-03-09 20:02:55.916684+01	t	11
75	75	\N	1	2026-03-09 20:02:55.916684+01	t	5
76	76	\N	1	2026-03-09 20:02:55.916684+01	t	6
77	77	\N	1	2026-03-09 20:02:55.916684+01	t	7
78	78	\N	1	2026-03-09 20:02:55.916684+01	t	8
80	80	\N	1	2026-03-09 20:02:55.916684+01	t	10
81	81	\N	1	2026-03-09 20:02:55.916684+01	t	11
82	82	\N	1	2026-03-09 20:02:55.916684+01	t	5
83	83	\N	1	2026-03-09 20:02:55.916684+01	t	6
84	84	\N	1	2026-03-09 20:02:55.916684+01	t	7
85	85	\N	1	2026-03-09 20:02:55.916684+01	t	8
87	87	\N	1	2026-03-09 20:02:55.916684+01	t	10
88	88	\N	1	2026-03-09 20:02:55.916684+01	t	11
89	89	\N	1	2026-03-09 20:02:55.916684+01	t	5
90	90	\N	1	2026-03-09 20:02:55.916684+01	t	6
91	91	\N	1	2026-03-09 20:02:55.916684+01	t	7
92	92	\N	1	2026-03-09 20:02:55.916684+01	t	8
94	94	\N	1	2026-03-09 20:02:55.916684+01	t	10
95	95	\N	1	2026-03-09 20:02:55.916684+01	t	11
96	96	\N	1	2026-03-09 20:02:55.916684+01	t	5
97	97	\N	1	2026-03-09 20:02:55.916684+01	t	6
98	98	\N	1	2026-03-09 20:02:55.916684+01	t	7
99	99	\N	1	2026-03-09 20:02:55.916684+01	t	8
101	101	\N	1	2026-03-09 20:02:55.916684+01	t	10
102	102	\N	1	2026-03-09 20:02:55.916684+01	t	11
103	103	\N	1	2026-03-09 20:02:55.916684+01	t	5
104	104	\N	1	2026-03-09 20:02:55.916684+01	t	6
105	105	\N	1	2026-03-09 20:02:55.916684+01	t	7
106	106	\N	1	2026-03-09 20:02:55.916684+01	t	8
108	108	\N	1	2026-03-09 20:02:55.916684+01	t	10
109	109	\N	1	2026-03-09 20:02:55.916684+01	t	11
110	110	\N	1	2026-03-09 20:02:55.916684+01	t	5
111	111	\N	1	2026-03-09 20:02:55.916684+01	t	6
112	112	\N	1	2026-03-09 20:02:55.916684+01	t	7
113	113	\N	1	2026-03-09 20:02:55.916684+01	t	8
115	115	\N	1	2026-03-09 20:02:55.916684+01	t	10
116	116	\N	1	2026-03-09 20:02:55.916684+01	t	11
117	117	\N	1	2026-03-09 20:02:55.916684+01	t	5
118	118	\N	1	2026-03-09 20:02:55.916684+01	t	6
119	119	\N	1	2026-03-09 20:02:55.916684+01	t	7
120	120	\N	1	2026-03-09 20:02:55.916684+01	t	8
122	122	\N	1	2026-03-09 20:02:55.916684+01	t	10
123	123	\N	1	2026-03-09 20:02:55.916684+01	t	11
124	124	\N	1	2026-03-09 20:02:55.916684+01	t	5
125	125	\N	1	2026-03-09 20:02:55.916684+01	t	6
126	126	\N	1	2026-03-09 20:02:55.916684+01	t	7
127	127	\N	1	2026-03-09 20:02:55.916684+01	t	8
129	129	\N	1	2026-03-09 20:02:55.916684+01	t	10
130	130	\N	1	2026-03-09 20:02:55.916684+01	t	11
131	131	\N	1	2026-03-09 20:02:55.916684+01	t	5
132	132	\N	1	2026-03-09 20:02:55.916684+01	t	6
133	133	\N	1	2026-03-09 20:02:55.916684+01	t	7
134	134	\N	1	2026-03-09 20:02:55.916684+01	t	8
136	136	\N	1	2026-03-09 20:02:55.916684+01	t	10
137	137	\N	1	2026-03-09 20:02:55.916684+01	t	11
138	138	\N	1	2026-03-09 20:02:55.916684+01	t	5
139	139	\N	1	2026-03-09 20:02:55.916684+01	t	6
140	140	\N	1	2026-03-09 20:02:55.916684+01	t	7
141	141	\N	1	2026-03-09 20:02:55.916684+01	t	8
143	143	\N	1	2026-03-09 20:02:55.916684+01	t	10
144	144	\N	1	2026-03-09 20:02:55.916684+01	t	11
145	145	\N	1	2026-03-09 20:02:55.916684+01	t	5
146	146	\N	1	2026-03-09 20:02:55.916684+01	t	6
147	147	\N	1	2026-03-09 20:02:55.916684+01	t	7
148	148	\N	1	2026-03-09 20:02:55.916684+01	t	8
150	150	\N	1	2026-03-09 20:02:55.916684+01	t	10
151	151	\N	1	2026-03-09 20:02:55.916684+01	t	11
152	152	\N	1	2026-03-09 20:02:55.916684+01	t	5
153	153	\N	1	2026-03-09 20:02:55.916684+01	t	6
154	154	\N	1	2026-03-09 20:02:55.916684+01	t	7
155	155	\N	1	2026-03-09 20:02:55.916684+01	t	8
157	157	\N	1	2026-03-09 20:02:55.916684+01	t	10
158	158	\N	1	2026-03-09 20:02:55.916684+01	t	11
159	159	\N	1	2026-03-09 20:02:55.916684+01	t	5
160	160	\N	1	2026-03-09 20:02:55.916684+01	t	6
161	161	\N	1	2026-03-09 20:02:55.916684+01	t	7
162	162	\N	1	2026-03-09 20:02:55.916684+01	t	8
164	164	\N	1	2026-03-09 20:02:55.916684+01	t	10
165	165	\N	1	2026-03-09 20:02:55.916684+01	t	11
166	166	\N	1	2026-03-09 20:02:55.916684+01	t	5
167	167	\N	1	2026-03-09 20:02:55.916684+01	t	6
168	168	\N	1	2026-03-09 20:02:55.916684+01	t	7
169	169	\N	1	2026-03-09 20:02:55.916684+01	t	8
171	171	\N	1	2026-03-09 20:02:55.916684+01	t	10
172	172	\N	1	2026-03-09 20:02:55.916684+01	t	11
173	173	\N	1	2026-03-09 20:02:55.916684+01	t	5
174	174	\N	1	2026-03-09 20:02:55.916684+01	t	6
175	175	\N	1	2026-03-09 20:02:55.916684+01	t	7
176	176	\N	1	2026-03-09 20:02:55.916684+01	t	8
178	178	\N	1	2026-03-09 20:02:55.916684+01	t	10
179	179	\N	1	2026-03-09 20:02:55.916684+01	t	11
180	180	\N	1	2026-03-09 20:02:55.916684+01	t	5
181	181	\N	1	2026-03-09 20:02:55.916684+01	t	6
182	182	\N	1	2026-03-09 20:02:55.916684+01	t	7
183	183	\N	1	2026-03-09 20:02:55.916684+01	t	8
185	185	\N	1	2026-03-09 20:02:55.916684+01	t	10
186	186	\N	1	2026-03-09 20:02:55.916684+01	t	11
187	187	\N	1	2026-03-09 20:02:55.916684+01	t	5
188	188	\N	1	2026-03-09 20:02:55.916684+01	t	6
189	189	\N	1	2026-03-09 20:02:55.916684+01	t	7
190	190	\N	1	2026-03-09 20:02:55.916684+01	t	8
192	192	\N	1	2026-03-09 20:02:55.916684+01	t	10
193	193	\N	1	2026-03-09 20:02:55.916684+01	t	11
194	194	\N	1	2026-03-09 20:02:55.916684+01	t	5
195	195	\N	1	2026-03-09 20:02:55.916684+01	t	6
196	196	\N	1	2026-03-09 20:02:55.916684+01	t	7
197	197	\N	1	2026-03-09 20:02:55.916684+01	t	8
199	199	\N	1	2026-03-09 20:02:55.916684+01	t	10
200	200	\N	1	2026-03-09 20:02:55.916684+01	t	11
201	201	\N	1	2026-03-09 20:02:55.916684+01	t	5
202	202	\N	1	2026-03-09 20:02:55.916684+01	t	6
203	203	\N	1	2026-03-09 20:02:55.916684+01	t	7
204	204	\N	1	2026-03-09 20:02:55.916684+01	t	8
206	206	\N	1	2026-03-09 20:02:55.916684+01	t	10
207	207	\N	1	2026-03-09 20:02:55.916684+01	t	11
208	208	\N	1	2026-03-09 20:02:55.916684+01	t	5
209	209	\N	1	2026-03-09 20:02:55.916684+01	t	6
210	210	\N	1	2026-03-09 20:02:55.916684+01	t	7
211	211	\N	1	2026-03-09 20:02:55.916684+01	t	8
213	213	\N	1	2026-03-09 20:02:55.916684+01	t	10
214	214	\N	1	2026-03-09 20:02:55.916684+01	t	11
215	215	\N	1	2026-03-09 20:02:55.916684+01	t	5
216	216	\N	1	2026-03-09 20:02:55.916684+01	t	6
217	217	\N	1	2026-03-09 20:02:55.916684+01	t	7
218	218	\N	1	2026-03-09 20:02:55.916684+01	t	8
220	220	\N	1	2026-03-09 20:02:55.916684+01	t	10
221	221	\N	1	2026-03-09 20:02:55.916684+01	t	11
222	222	\N	1	2026-03-09 20:02:55.916684+01	t	5
223	223	\N	1	2026-03-09 20:02:55.916684+01	t	6
224	224	\N	1	2026-03-09 20:02:55.916684+01	t	7
225	225	\N	1	2026-03-09 20:02:55.916684+01	t	8
227	227	\N	1	2026-03-09 20:02:55.916684+01	t	10
228	228	\N	1	2026-03-09 20:02:55.916684+01	t	11
229	229	\N	1	2026-03-09 20:02:55.916684+01	t	5
230	230	\N	1	2026-03-09 20:02:55.916684+01	t	6
231	231	\N	1	2026-03-09 20:02:55.916684+01	t	7
232	232	\N	1	2026-03-09 20:02:55.916684+01	t	8
234	234	\N	1	2026-03-09 20:02:55.916684+01	t	10
235	235	\N	1	2026-03-09 20:02:55.916684+01	t	11
236	236	\N	1	2026-03-09 20:02:55.916684+01	t	5
237	237	\N	1	2026-03-09 20:02:55.916684+01	t	6
238	238	\N	1	2026-03-09 20:02:55.916684+01	t	7
239	239	\N	1	2026-03-09 20:02:55.916684+01	t	8
121	121	5	1	2026-03-09 20:02:55.916684+01	t	9
241	241	\N	1	2026-03-09 20:02:55.916684+01	t	10
242	242	\N	1	2026-03-09 20:02:55.916684+01	t	11
243	243	\N	1	2026-03-09 20:02:55.916684+01	t	5
244	244	\N	1	2026-03-09 20:02:55.916684+01	t	6
245	245	\N	1	2026-03-09 20:02:55.916684+01	t	7
246	246	\N	1	2026-03-09 20:02:55.916684+01	t	8
248	248	\N	1	2026-03-09 20:02:55.916684+01	t	10
249	249	\N	1	2026-03-09 20:02:55.916684+01	t	11
250	250	\N	1	2026-03-09 20:02:55.916684+01	t	5
251	251	\N	1	2026-03-09 20:02:55.916684+01	t	6
252	252	\N	1	2026-03-09 20:02:55.916684+01	t	7
253	253	\N	1	2026-03-09 20:02:55.916684+01	t	8
255	255	\N	1	2026-03-09 20:02:55.916684+01	t	10
256	256	\N	1	2026-03-09 20:02:55.916684+01	t	11
257	257	\N	1	2026-03-09 20:02:55.916684+01	t	5
258	258	\N	1	2026-03-09 20:02:55.916684+01	t	6
259	259	\N	1	2026-03-09 20:02:55.916684+01	t	7
260	260	\N	1	2026-03-09 20:02:55.916684+01	t	8
262	262	\N	1	2026-03-09 20:02:55.916684+01	t	10
263	263	\N	1	2026-03-09 20:02:55.916684+01	t	11
264	264	\N	1	2026-03-09 20:02:55.916684+01	t	5
265	265	\N	1	2026-03-09 20:02:55.916684+01	t	6
266	266	\N	1	2026-03-09 20:02:55.916684+01	t	7
267	267	\N	1	2026-03-09 20:02:55.916684+01	t	8
269	269	\N	1	2026-03-09 20:02:55.916684+01	t	10
270	270	\N	1	2026-03-09 20:02:55.916684+01	t	11
271	271	\N	1	2026-03-09 20:02:55.916684+01	t	5
272	272	\N	1	2026-03-09 20:02:55.916684+01	t	6
273	273	\N	1	2026-03-09 20:02:55.916684+01	t	7
274	274	\N	1	2026-03-09 20:02:55.916684+01	t	8
276	276	\N	1	2026-03-09 20:02:55.916684+01	t	10
277	277	\N	1	2026-03-09 20:02:55.916684+01	t	11
278	278	\N	1	2026-03-09 20:02:55.916684+01	t	5
279	279	\N	1	2026-03-09 20:02:55.916684+01	t	6
280	280	\N	1	2026-03-09 20:02:55.916684+01	t	7
281	281	\N	1	2026-03-09 20:02:55.916684+01	t	8
283	283	\N	1	2026-03-09 20:02:55.916684+01	t	10
284	284	\N	1	2026-03-09 20:02:55.916684+01	t	11
285	285	\N	1	2026-03-09 20:02:55.916684+01	t	5
286	286	\N	1	2026-03-09 20:02:55.916684+01	t	6
287	287	\N	1	2026-03-09 20:02:55.916684+01	t	7
288	288	\N	1	2026-03-09 20:02:55.916684+01	t	8
290	290	\N	1	2026-03-09 20:02:55.916684+01	t	10
291	291	\N	1	2026-03-09 20:02:55.916684+01	t	11
292	292	\N	1	2026-03-09 20:02:55.916684+01	t	5
293	293	\N	1	2026-03-09 20:02:55.916684+01	t	6
294	294	\N	1	2026-03-09 20:02:55.916684+01	t	7
295	295	\N	1	2026-03-09 20:02:55.916684+01	t	8
297	297	\N	1	2026-03-09 20:02:55.916684+01	t	10
298	298	\N	1	2026-03-09 20:02:55.916684+01	t	11
299	299	\N	1	2026-03-09 20:02:55.916684+01	t	5
300	300	\N	1	2026-03-09 20:02:55.916684+01	t	6
301	301	\N	1	2026-03-09 20:02:55.916684+01	t	7
302	302	\N	1	2026-03-09 20:02:55.916684+01	t	8
304	304	\N	1	2026-03-09 20:02:55.916684+01	t	10
305	305	\N	1	2026-03-09 20:02:55.916684+01	t	11
306	306	\N	1	2026-03-09 20:02:55.916684+01	t	5
307	307	\N	1	2026-03-09 20:02:55.916684+01	t	6
308	308	\N	1	2026-03-09 20:02:55.916684+01	t	7
309	309	\N	1	2026-03-09 20:02:55.916684+01	t	8
311	311	\N	1	2026-03-09 20:02:55.916684+01	t	10
312	312	\N	1	2026-03-09 20:02:55.916684+01	t	11
313	313	\N	1	2026-03-09 20:02:55.916684+01	t	5
314	314	\N	1	2026-03-09 20:02:55.916684+01	t	6
315	315	\N	1	2026-03-09 20:02:55.916684+01	t	7
316	316	\N	1	2026-03-09 20:02:55.916684+01	t	8
318	318	\N	1	2026-03-09 20:02:55.916684+01	t	10
319	319	\N	1	2026-03-09 20:02:55.916684+01	t	11
320	320	\N	1	2026-03-09 20:02:55.916684+01	t	5
321	321	\N	1	2026-03-09 20:02:55.916684+01	t	6
322	322	\N	1	2026-03-09 20:02:55.916684+01	t	7
323	323	\N	1	2026-03-09 20:02:55.916684+01	t	8
325	325	\N	1	2026-03-09 20:02:55.916684+01	t	10
326	326	\N	1	2026-03-09 20:02:55.916684+01	t	11
327	327	\N	1	2026-03-09 20:02:55.916684+01	t	5
328	328	\N	1	2026-03-09 20:02:55.916684+01	t	6
329	329	\N	1	2026-03-09 20:02:55.916684+01	t	7
330	330	\N	1	2026-03-09 20:02:55.916684+01	t	8
332	332	\N	1	2026-03-09 20:02:55.916684+01	t	10
333	333	\N	1	2026-03-09 20:02:55.916684+01	t	11
334	334	\N	1	2026-03-09 20:02:55.916684+01	t	5
335	335	\N	1	2026-03-09 20:02:55.916684+01	t	6
336	336	\N	1	2026-03-09 20:02:55.916684+01	t	7
337	337	\N	1	2026-03-09 20:02:55.916684+01	t	8
339	339	\N	1	2026-03-09 20:02:55.916684+01	t	10
340	340	\N	1	2026-03-09 20:02:55.916684+01	t	11
341	341	\N	1	2026-03-09 20:02:55.916684+01	t	5
342	342	\N	1	2026-03-09 20:02:55.916684+01	t	6
343	343	\N	1	2026-03-09 20:02:55.916684+01	t	7
344	344	\N	1	2026-03-09 20:02:55.916684+01	t	8
346	346	\N	1	2026-03-09 20:02:55.916684+01	t	10
347	347	\N	1	2026-03-09 20:02:55.916684+01	t	11
348	348	\N	1	2026-03-09 20:02:55.916684+01	t	5
349	349	\N	1	2026-03-09 20:02:55.916684+01	t	6
350	350	\N	1	2026-03-09 20:02:55.916684+01	t	7
351	351	\N	1	2026-03-09 20:02:55.916684+01	t	8
353	353	\N	1	2026-03-09 20:02:55.916684+01	t	10
354	354	\N	1	2026-03-09 20:02:55.916684+01	t	11
331	331	2	1	2026-03-09 20:02:55.916684+01	t	9
338	338	2	1	2026-03-09 20:02:55.916684+01	t	9
324	324	3	1	2026-03-09 20:02:55.916684+01	t	9
345	345	3	1	2026-03-09 20:02:55.916684+01	t	9
352	352	3	1	2026-03-09 20:02:55.916684+01	t	9
226	226	4	1	2026-03-09 20:02:55.916684+01	t	9
233	233	4	1	2026-03-09 20:02:55.916684+01	t	9
240	240	4	1	2026-03-09 20:02:55.916684+01	t	9
247	247	4	1	2026-03-09 20:02:55.916684+01	t	9
254	254	4	1	2026-03-09 20:02:55.916684+01	t	9
261	261	4	1	2026-03-09 20:02:55.916684+01	t	9
268	268	4	1	2026-03-09 20:02:55.916684+01	t	9
275	275	4	1	2026-03-09 20:02:55.916684+01	t	9
282	282	4	1	2026-03-09 20:02:55.916684+01	t	9
289	289	4	1	2026-03-09 20:02:55.916684+01	t	9
296	296	4	1	2026-03-09 20:02:55.916684+01	t	9
303	303	4	1	2026-03-09 20:02:55.916684+01	t	9
310	310	4	1	2026-03-09 20:02:55.916684+01	t	9
317	317	4	1	2026-03-09 20:02:55.916684+01	t	9
9	9	5	1	2026-03-09 20:02:55.916684+01	t	9
16	16	5	1	2026-03-09 20:02:55.916684+01	t	9
23	23	5	1	2026-03-09 20:02:55.916684+01	t	9
30	30	5	1	2026-03-09 20:02:55.916684+01	t	9
37	37	5	1	2026-03-09 20:02:55.916684+01	t	9
44	44	5	1	2026-03-09 20:02:55.916684+01	t	9
51	51	5	1	2026-03-09 20:02:55.916684+01	t	9
58	58	5	1	2026-03-09 20:02:55.916684+01	t	9
65	65	5	1	2026-03-09 20:02:55.916684+01	t	9
72	72	5	1	2026-03-09 20:02:55.916684+01	t	9
79	79	5	1	2026-03-09 20:02:55.916684+01	t	9
86	86	5	1	2026-03-09 20:02:55.916684+01	t	9
93	93	5	1	2026-03-09 20:02:55.916684+01	t	9
100	100	5	1	2026-03-09 20:02:55.916684+01	t	9
107	107	5	1	2026-03-09 20:02:55.916684+01	t	9
114	114	5	1	2026-03-09 20:02:55.916684+01	t	9
128	128	5	1	2026-03-09 20:02:55.916684+01	t	9
135	135	5	1	2026-03-09 20:02:55.916684+01	t	9
142	142	5	1	2026-03-09 20:02:55.916684+01	t	9
149	149	5	1	2026-03-09 20:02:55.916684+01	t	9
156	156	5	1	2026-03-09 20:02:55.916684+01	t	9
163	163	5	1	2026-03-09 20:02:55.916684+01	t	9
170	170	5	1	2026-03-09 20:02:55.916684+01	t	9
177	177	5	1	2026-03-09 20:02:55.916684+01	t	9
184	184	5	1	2026-03-09 20:02:55.916684+01	t	9
191	191	5	1	2026-03-09 20:02:55.916684+01	t	9
198	198	5	1	2026-03-09 20:02:55.916684+01	t	9
205	205	5	1	2026-03-09 20:02:55.916684+01	t	9
212	212	5	1	2026-03-09 20:02:55.916684+01	t	9
219	219	5	1	2026-03-09 20:02:55.916684+01	t	9
\.


--
-- Data for Name: grade_scheme_values; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.grade_scheme_values (value_id, scheme_id, code, label, sort_order, is_passing) FROM stdin;
\.


--
-- Data for Name: grade_schemes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.grade_schemes (scheme_id, name, is_active, created_at) FROM stdin;
\.


--
-- Data for Name: grades; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.grades (grade_id, student_id, course_id, term_id, scheme_value_id, recorded_by, created_at, comment, mark) FROM stdin;
\.


--
-- Data for Name: migrations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.migrations (id, "timestamp", name) FROM stdin;
1	1760037856494	AddGuardrails1760037856494
2	1760051000000	AlignSchemaWithApi1760051000000
3	1760065000000	TightenEnrollmentsAndTimetable1760065000000
4	1760067000000	AddPrintGenerationSeq1760067000000
5	1760070000000	UpdateTimetableSlotsDuration1760070000000
6	1760074000000	NotificationsStudentCategory1760074000000
7	1760075000000	ConvertGradesMarkToNumeric1760075000000
8	1763584000000	AddTimetableDivision1763584000000
9	1763608000000	AttendanceUniquenessGuardrails1763608000000
10	1768700000000	AddCurriculumAndCourseInstanceScope1768700000000
11	1768705000000	AddTeacherSubjects1768705000000
12	1769000000000	AddCurriculumTracks1769000000000
13	1771976231265	AddSpecializationAreaLinks1771976231265
14	1771976533029	AddSpecializationAreaLinksFix1771976533029
15	1771978000000	UpdateCurriculumItemsSubjectCascade1771978000000
16	1772000000000	AddEnrollmentGradeLevel1772000000000
17	1771979000000	AddBuildingsAndLinkClassrooms1771979000000
18	1771980000000	AddBuildingFlags1771980000000
19	1771990000000	AddClassGroupFixedLocations1771990000000
20	1772200000000	AddUserPasswordFlags1772200000000
21	1772300000000	AddStudentGender1772300000000
22	1773700000000	AddPlanillaSheets1773700000000
\.


--
-- Data for Name: notifications; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.notifications (notification_id, created_by, created_at, title, message, is_active, category, student_id) FROM stdin;
\.


--
-- Data for Name: planilla_sheets; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.planilla_sheets (planilla_sheet_id, school_year_id, class_group_id, grade_level, section, group_code, source_sheet, source_file_name, template_key, title, metadata, columns, rows, is_active, imported_by, imported_at, updated_at) FROM stdin;
1	1	\N	6	01	601	6°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 601	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "6°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "601-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ALDANA VALENZUELA MARIA JOSE", "normalizedName": "aldana valenzuela maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "601-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ALVAREZ MUÑOZ ZOE LUCIANA", "normalizedName": "alvarez munoz zoe luciana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "601-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRAGAN QUINTANA SERGIO", "normalizedName": "barragan quintana sergio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "601-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRERO BERNAL JOHAN SANTIAGO", "normalizedName": "barrero bernal johan santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "601-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTIBLANCO VANEGAS ZULLY MARIANA", "normalizedName": "castiblanco vanegas zully mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "601-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO GOYENECHE GABRIELA", "normalizedName": "castillo goyeneche gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "601-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CATAÑO BECERRA ISABELLA", "normalizedName": "catano becerra isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "601-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CIFUENTES CRUZ SARA", "normalizedName": "cifuentes cruz sara"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "601-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FRADE CASTAÑEDA SARA VALENTINA", "normalizedName": "frade castaneda sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "601-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GONZALEZ GUZMAN ANA MARIA", "normalizedName": "gonzalez guzman ana maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "601-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOYENECHE MARTINEZ SAMUEL ESTEBAN", "normalizedName": "goyeneche martinez samuel esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "601-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUAYANA RODRIGUEZ THANIA", "normalizedName": "guayana rodriguez thania"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "601-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ MERCADO NICOLAS", "normalizedName": "gutierrez mercado nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "601-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HUERFANO FORERO LIZETH KATERIN", "normalizedName": "huerfano forero lizeth katerin"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "601-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LONGAS HERNANDEZ ANDRES FELIPE", "normalizedName": "longas hernandez andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "601-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON VARGAS FRANK NICOLAS RICARDO", "normalizedName": "malagon vargas frank nicolas ricardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "601-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARIN GUARIN LAURA SOFIA", "normalizedName": "marin guarin laura sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "601-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NOVA NAVARRETE CARLOS STIVEN", "normalizedName": "nova navarrete carlos stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "601-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OTALORA CASALLAS MARIA JOSE", "normalizedName": "otalora casallas maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "601-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ RODRIGUEZ AIREHT XIOMARA", "normalizedName": "perez rodriguez aireht xiomara"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "601-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON HEREDIA SAMUEL ESTEVAN", "normalizedName": "pinzon heredia samuel estevan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "601-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO BERMUDEZ MARIA JOSE", "normalizedName": "quintero bermudez maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "601-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ COBOS DANNA VALENTINA", "normalizedName": "ramirez cobos danna valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "601-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ NIÑO DANIEL CAMILO", "normalizedName": "rodriguez nino daniel camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "601-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ SARMIENTO JUAN SEBASTIAN", "normalizedName": "rodriguez sarmiento juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "601-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROLDAN CASTRO MARIA JOSE", "normalizedName": "roldan castro maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "601-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTAFE CASTILLO SAMMY LUCIANA", "normalizedName": "santafe castillo sammy luciana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "601-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUA FARFAN ANDRES STIVEN", "normalizedName": "sua farfan andres stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "601-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES GUERRERO SARA NICOLLE", "normalizedName": "torres guerrero sara nicolle"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "601-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES RODRIGUEZ DANNA GABRIELA", "normalizedName": "torres rodriguez danna gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "601-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALERO VILLALOBOS VALERY GABRIELA", "normalizedName": "valero villalobos valery gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "601-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALIENTE MONTENEGRO SAMUEL JERONIMO", "normalizedName": "valiente montenegro samuel jeronimo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "601-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VASQUEZ CASTILLO EVELYN MARIANA", "normalizedName": "vasquez castillo evelyn mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "601-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA GALVIS SETH ALEJANDRO", "normalizedName": "zamora galvis seth alejandro"}]	t	900100	2026-03-17 15:31:22.300563+01	2026-03-17 15:31:22.300563+01
2	1	\N	6	02	602	6°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 602	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "6°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "602-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABELLO MALDONADO ALISSON VALERIA", "normalizedName": "abello maldonado alisson valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "602-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ARIAS ARIZA ADRIANA VALENTINA", "normalizedName": "arias ariza adriana valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "602-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AYALA HERRERA PAULA STEPHANIE", "normalizedName": "ayala herrera paula stephanie"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "602-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BERMUDEZ ROBAYO SHAROTH SALOME", "normalizedName": "bermudez robayo sharoth salome"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "602-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUSTOS BOLIVAR VALERYE FERNANDA", "normalizedName": "bustos bolivar valerye fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "602-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASAS QUEVEDO DANNA SOFIA", "normalizedName": "casas quevedo danna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "602-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO BERNAL HELLEN SOFIA", "normalizedName": "castillo bernal hellen sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "602-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAUTA MAMANCHE SUATY GOSKUA", "normalizedName": "chauta mamanche suaty goskua"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "602-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DURAN CUEVAS SANDRA MILENA", "normalizedName": "duran cuevas sandra milena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "602-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FERNANDEZ CASTRO PAULA NICOLE", "normalizedName": "fernandez castro paula nicole"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "602-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA GOMEZ JOHAN SEBASTIAN", "normalizedName": "garcia gomez johan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "602-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON BARRIGA GENRY", "normalizedName": "garzon barriga genry"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "602-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GOMEZ ERIKA YISNEY", "normalizedName": "gil gomez erika yisney"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "602-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ CASTRO SHARITH YESENNIA", "normalizedName": "gomez castro sharith yesennia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "602-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ BOJACA MANUEL JOSE", "normalizedName": "lopez bojaca manuel jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "602-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MELLIZO COMBA EDWAR ARMANDO", "normalizedName": "mellizo comba edwar armando"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "602-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MURCIA FORERO ANA XIMENA", "normalizedName": "murcia forero ana ximena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "602-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON BENAVIDES THOMAS ALEJANDRO", "normalizedName": "pinzon benavides thomas alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "602-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON QUINTERO NIKOL VALERIA", "normalizedName": "pinzon quintero nikol valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "602-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUEVEDO SEGURA ANDRES FELIPE", "normalizedName": "quevedo segura andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "602-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO FERNANDEZ ANA SOPHIA", "normalizedName": "quintero fernandez ana sophia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "602-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO MARTINEZ JEISON ALEJANDRO", "normalizedName": "quintero martinez jeison alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "602-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUIROGA BARRIGA IVAN LORENZO", "normalizedName": "quiroga barriga ivan lorenzo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "602-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIOS RODRIGUEZ JUAN ESTEBAN", "normalizedName": "rios rodriguez juan esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "602-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROJAS GONZALEZ JUAN JOSE", "normalizedName": "rojas gonzalez juan jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "602-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUBIANO MELO MIGUEL EDUARDO", "normalizedName": "rubiano melo miguel eduardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "602-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SABOYA PRIETO MIGUEL ANGEL", "normalizedName": "saboya prieto miguel angel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "602-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SALAS BECERRA DANNA SARAY", "normalizedName": "salas becerra danna saray"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "602-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ DOZA DAVID ESTEBAN", "normalizedName": "sanchez doza david esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "602-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES VAQUIRO BRAYAN ALEXANDER", "normalizedName": "torres vaquiro brayan alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "602-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VILLALOBOS ACEVEDO DAVID SANTIAGO", "normalizedName": "villalobos acevedo david santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "602-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "YEPES SARMIENTO ANDERSON DAVID", "normalizedName": "yepes sarmiento anderson david"}]	t	900100	2026-03-17 15:31:22.312485+01	2026-03-17 15:31:22.312485+01
3	1	\N	6	03	603	6°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 603	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "6°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "603-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL PASCAGAZA JOHAN EDILSON", "normalizedName": "abril pascagaza johan edilson"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "603-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ACOSTA LEON JUAN ESTEBAN", "normalizedName": "acosta leon juan esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "603-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AVENDAÑO GOMEZ SARA SOFIA", "normalizedName": "avendano gomez sara sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "603-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDEZ ABRIL LUNA SALOME", "normalizedName": "benavidez abril luna salome"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "603-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAMARGO GUALTEROS WILDER SANTIAGO", "normalizedName": "camargo gualteros wilder santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "603-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA CASTRO SAMUEL DAVID", "normalizedName": "castaneda castro samuel david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "603-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO MAYORGA KEVIN ANDRES", "normalizedName": "castro mayorga kevin andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "603-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO MILAGUY ADRIAN DAVID", "normalizedName": "castro milaguy adrian david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "603-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUBILLOS CHAPARRO THOMAS CAMILO", "normalizedName": "cubillos chaparro thomas camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "603-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESPINOSA LOPEZ SARA JULIANA", "normalizedName": "espinosa lopez sara juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "603-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON CASTRO KAROL GINETH", "normalizedName": "garzon castro karol gineth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "603-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ LEON DAYRON ALEJANDRO", "normalizedName": "gomez leon dayron alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "603-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GONZALEZ UMBARILA JUAN SEBASTIAN", "normalizedName": "gonzalez umbarila juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "603-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUALTEROS CASTRO JOHAN ANDREY", "normalizedName": "gualteros castro johan andrey"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "603-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERRERA SUAREZ LUCIANA ALEJANDRA", "normalizedName": "herrera suarez luciana alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "603-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ ALVAREZ SARAY MILENA", "normalizedName": "lopez alvarez saray milena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "603-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MADRID GARZON KAROL DANIELA", "normalizedName": "madrid garzon karol daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "603-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MAHECHA YALANDA ALEXANDER", "normalizedName": "mahecha yalanda alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "603-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALO ALIMAKO DEISY LILIANA", "normalizedName": "malo alimako deisy liliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "603-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARTINEZ VELA JEFERSON STIVEN", "normalizedName": "martinez vela jeferson stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "603-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO CASTILLO JOHAN SEBASTIAN", "normalizedName": "montenegro castillo johan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "603-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NIÑO CHICAGUY JUAN JOSE", "normalizedName": "nino chicaguy juan jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "603-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OCAMPO NOSCUE JAROL ESTIVEN", "normalizedName": "ocampo noscue jarol estiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "603-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEDREROS PEDREROS MIGUEL ANGEL", "normalizedName": "pedreros pedreros miguel angel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "603-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEÑA VALERO JUAN SEBASTIAN", "normalizedName": "pena valero juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "603-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON GORDILLO WILMAR ANDRES", "normalizedName": "pinzon gordillo wilmar andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "603-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIAÑO PIÑEROS SERGIO SEBASTIAN", "normalizedName": "riano pineros sergio sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "603-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RINCON LIZARAZO BRAYAN STIVEN", "normalizedName": "rincon lizarazo brayan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "603-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SORIANO MARIN AILEEN VICTORIA", "normalizedName": "soriano marin aileen victoria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "603-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VANEGAS LOPEZ EMILY MARIANA", "normalizedName": "vanegas lopez emily mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "603-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VARGAS GOMEZ DANNA ISABELLA", "normalizedName": "vargas gomez danna isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "603-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA FARFAN HAROLD NICOLAS", "normalizedName": "zamora farfan harold nicolas"}]	t	900100	2026-03-17 15:31:22.315214+01	2026-03-17 15:31:22.315214+01
4	1	\N	6	04	604	6°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 604	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "6°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "604-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO BOJACA JUAN SEBASTIAN", "normalizedName": "arevalo bojaca juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "604-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO RIAÑO SAMUEL DAVID", "normalizedName": "arevalo riano samuel david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "604-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BALAGUERA FARFAN ALISSON GABRIELA", "normalizedName": "balaguera farfan alisson gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "604-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BETANCOURT BARRIGA EDISSON SANTIAGO", "normalizedName": "betancourt barriga edisson santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "604-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUSTOS LOPEZ AARON JOSUE", "normalizedName": "bustos lopez aaron josue"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "604-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CALLEJAS ROMERO DAVID SANTIAGO", "normalizedName": "callejas romero david santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "604-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO ROBAYO MARA ESTEFANIA", "normalizedName": "castro robayo mara estefania"}, {"note": "N II-25", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "604-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUESTA RAMIREZ MARIA ANGEL", "normalizedName": "cuesta ramirez maria angel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "604-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FARFAN FARFAN EDWARD DAVID", "normalizedName": "farfan farfan edward david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "604-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FLEIRES LUZARDO ALEX RODRIGO", "normalizedName": "fleires luzardo alex rodrigo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "604-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO JIMENEZ HAROLD DAVID", "normalizedName": "forero jimenez harold david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "604-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO LOPEZ INGRID MARIANA", "normalizedName": "forero lopez ingrid mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "604-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GAMBA MOLINA LOREN SOFIA", "normalizedName": "gamba molina loren sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "604-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GOMEZ JEIMY LIZETH", "normalizedName": "gil gomez jeimy lizeth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "604-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ TORRES BRANDON SMITH", "normalizedName": "gomez torres brandon smith"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "604-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ UMBARILA DANNA GABRIELA", "normalizedName": "gomez umbarila danna gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "604-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "IBAGUE RODRIGUEZ ALISON XIMENA", "normalizedName": "ibague rodriguez alison ximena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "604-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA RAVELO ANDRES MAURICIO", "normalizedName": "lara ravelo andres mauricio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "604-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LEON VILLALBA DIEGO ALEJANDRO", "normalizedName": "leon villalba diego alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "604-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOBO GARCIA DEIVID ANDRES", "normalizedName": "lobo garcia deivid andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "604-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ FRANCO MATIAS CAMILO", "normalizedName": "lopez franco matias camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "604-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARIN CORTES MARIA JOSE", "normalizedName": "marin cortes maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "604-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA MORA LINA MARIANA", "normalizedName": "mora mora lina mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "604-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PAEZ SUAREZ GOJAN ALEJANDRO", "normalizedName": "paez suarez gojan alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "604-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PASCAGAZA GOMEZ BERNARDO ALEJANDRO", "normalizedName": "pascagaza gomez bernardo alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "604-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUETE MARCHAN HEIMY YOMAR", "normalizedName": "quete marchan heimy yomar"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "604-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ FORERO ADRIAN LEANDRO", "normalizedName": "ramirez forero adrian leandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "604-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ CIFUENTES MARLON DANIEL", "normalizedName": "sanchez cifuentes marlon daniel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "604-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SOTELO PENAGOS ZULAY DANIELA", "normalizedName": "sotelo penagos zulay daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "604-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUAREZ SUAREZ ANA VICTORIA", "normalizedName": "suarez suarez ana victoria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "604-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALBUENA SUAREZ TANIA VALERIA", "normalizedName": "valbuena suarez tania valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "604-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VELANDIA SUAREZ JULIAN DAVID", "normalizedName": "velandia suarez julian david"}]	t	900100	2026-03-17 15:31:22.317953+01	2026-03-17 15:31:22.317953+01
5	1	\N	6	05	605	6°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 605	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "6°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "605-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL BENAVIDES CRISTIAN DANIEL", "normalizedName": "abril benavides cristian daniel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "605-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL LOPEZ JHONATAN ALEXIS", "normalizedName": "abril lopez jhonatan alexis"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "605-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ARANDA RODRIGUEZ JEISSY LUCIANA", "normalizedName": "aranda rodriguez jeissy luciana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "605-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BERNAL ABRIL LEIDY YULIANA", "normalizedName": "bernal abril leidy yuliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "605-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA GARCIA EDWAR GABRIEL", "normalizedName": "cabuya garcia edwar gabriel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "605-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRISTANCHO CRISTANCHO MARIA FERNANDA", "normalizedName": "cristancho cristancho maria fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "605-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ GALINDO ESNEIDER NICOLAS", "normalizedName": "cruz galindo esneider nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "605-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DUEÑAS RODRIGUEZ IVAN CAMILO", "normalizedName": "duenas rodriguez ivan camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "605-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESPINOSA LOPEZ KAREN DAYANA", "normalizedName": "espinosa lopez karen dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "605-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO SANCHEZ JUAN MANUEL", "normalizedName": "forero sanchez juan manuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "605-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA BUSTOS DENNIS GABRIELA", "normalizedName": "garcia bustos dennis gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "605-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA MEDINA LINA ESTEFANIA", "normalizedName": "garcia medina lina estefania"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "605-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ MARTINEZ LUIS SANTIAGO", "normalizedName": "gomez martinez luis santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "605-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUAYAMBUCO ROMERO ZARETH GABRIELA", "normalizedName": "guayambuco romero zareth gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "605-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LINARES CHAVEZ ADRIANA MISHELL", "normalizedName": "linares chavez adriana mishell"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "605-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MADARRIAGA GONZALEZ JHOLFRANK JHONAIKER", "normalizedName": "madarriaga gonzalez jholfrank jhonaiker"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "605-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MELO VENEGAS JHON MARLON", "normalizedName": "melo venegas jhon marlon"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "605-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO RAMIREZ MABELL VALERIA", "normalizedName": "montenegro ramirez mabell valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "605-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTOYA MAYORGA KEVIN SANTIAGO", "normalizedName": "montoya mayorga kevin santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "605-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA SEGURA JHONATAN DAVID", "normalizedName": "mora segura jhonatan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "605-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON CASTRO JUAN SEBASTIAN", "normalizedName": "pinzon castro juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "605-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON GUALTEROS ZULY ALEXANDRA", "normalizedName": "pinzon gualteros zuly alexandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "605-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON SUBA EDWARD ALEXIS", "normalizedName": "pinzon suba edward alexis"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "605-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ CASTILLO CRISTIAN FERNEY", "normalizedName": "ramirez castillo cristian ferney"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "605-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SEGURA CUERVO BRAYAN ESTIBEN", "normalizedName": "segura cuervo brayan estiben"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "605-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SILVA GALINDO JUAN DIEGO", "normalizedName": "silva galindo juan diego"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "605-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SOSA ALISON LISBET", "normalizedName": "sosa alison lisbet"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "605-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUAREZ TORRES MICHELLE ELIANA", "normalizedName": "suarez torres michelle eliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "605-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA MORA LEIDY STEFANIA", "normalizedName": "zamora mora leidy stefania"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "605-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA PINZON SARA VALENTINA", "normalizedName": "zamora pinzon sara valentina"}, {"note": "Ret III-4", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "605-31", "status": "retired", "retired": true, "studentId": null, "nationalId": null, "studentName": "VARGAS VELEZ SARA VALENTINA", "normalizedName": "vargas velez sara valentina"}]	t	900100	2026-03-17 15:31:22.32176+01	2026-03-17 15:31:22.32176+01
6	1	\N	6	06	606	6°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 606	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "6°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "606-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ARIZA CUERVO FABIAN STIVEN", "normalizedName": "ariza cuervo fabian stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "606-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BRAVO CABALLERO FHERLYK SHIRLEY", "normalizedName": "bravo caballero fherlyk shirley"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "606-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARDENAS MURCIA ELDY DAYANNA", "normalizedName": "cardenas murcia eldy dayanna"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "606-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA LAMPREA DEIVY JULIAN", "normalizedName": "castaneda lamprea deivy julian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "606-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTIBLANCO AREVALO JIMMY ALEJANDRO", "normalizedName": "castiblanco arevalo jimmy alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "606-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO AREVALO HECTOR FERNANDO", "normalizedName": "castro arevalo hector fernando"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "606-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CETINA PEDRAZA MICHAEL SNEIDER", "normalizedName": "cetina pedraza michael sneider"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "606-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAVES CARDENAS MIGUEL ANGEL", "normalizedName": "chaves cardenas miguel angel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "606-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO AREVALO YEIMI VANESA", "normalizedName": "forero arevalo yeimi vanesa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "606-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GALEANO CASALLAS YEIMY FERNANDA", "normalizedName": "galeano casallas yeimy fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "606-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA ARENAS KEVIN ANDRES", "normalizedName": "garcia arenas kevin andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "606-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA POVEDA DILAN NICOLAS", "normalizedName": "garcia poveda dilan nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "606-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON HERNANDEZ JHON SAMIR", "normalizedName": "garzon hernandez jhon samir"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "606-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON VERA JESSICA ALEJANDRA", "normalizedName": "garzon vera jessica alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "606-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GORDILLO PERALTA IAN SANTIAGO", "normalizedName": "gordillo peralta ian santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "606-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ GOMEZ ANDRES SANTIAGO", "normalizedName": "gutierrez gomez andres santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "606-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ RIAÑO ALEXANDRA GINETH", "normalizedName": "hernandez riano alexandra gineth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "606-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JIMENEZ CASTAÑEDA SAMUEL STEVEN", "normalizedName": "jimenez castaneda samuel steven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "606-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON BULLA HAROLD STIVEN", "normalizedName": "malagon bulla harold stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "606-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA MOJICA LOSRID SANTIAGO", "normalizedName": "mora mojica losrid santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "606-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON PASCAGAZA IVAN LEONARDO", "normalizedName": "pinzon pascagaza ivan leonardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "606-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAQUIRA VALERO JHON ALEX", "normalizedName": "raquira valero jhon alex"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "606-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "REINA MORA DANNA SOFIA", "normalizedName": "reina mora danna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "606-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROBERTO MARTINEZ KEVIN SANTIAGO", "normalizedName": "roberto martinez kevin santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "606-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROCHA AVENDAÑO VALERY JIMENA", "normalizedName": "rocha avendano valery jimena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "606-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES AREVALO YOJAN STIVEN", "normalizedName": "torres arevalo yojan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "606-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VARGAS BARRETO CRISTIAN DAVID", "normalizedName": "vargas barreto cristian david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "606-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUPAJITA GARCIA SHEILAN SARITA Ret III-9)", "normalizedName": "cupajita garcia sheilan sarita ret iii 9"}]	t	900100	2026-03-17 15:31:22.324057+01	2026-03-17 15:31:22.324057+01
7	1	\N	7	01	701	7°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 701	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "7°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "701-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO CASALLAS SAMUEL LEONARDO", "normalizedName": "arevalo casallas samuel leonardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "701-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARAJAS DEAZA SARA VALENTINA", "normalizedName": "barajas deaza sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "701-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES ABRIL KAREN VALENTINA", "normalizedName": "benavides abril karen valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "701-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES AVENDAÑO YOHAN DAVID", "normalizedName": "benavides avendano yohan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "701-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA SUA DANNA CAMILA", "normalizedName": "cabuya sua danna camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "701-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARRILLO VERDUGO MARIO ANDRES", "normalizedName": "carrillo verdugo mario andres"}, {"note": "N II-25", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "701-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTELBALNCO ORJUELA ALINA", "normalizedName": "castelbalnco orjuela alina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "701-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO AGUIRRE ANDRES FELIPE", "normalizedName": "castro aguirre andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "701-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CORONADO RODRIGUEZ DANNA SOFIA", "normalizedName": "coronado rodriguez danna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "701-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ CANO ANYI DANIELA", "normalizedName": "cruz cano anyi daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "701-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DE PABLOS LARA DYLAN JULIAN", "normalizedName": "de pablos lara dylan julian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "701-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FARFAN GIL PAULA GABRIELA", "normalizedName": "farfan gil paula gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "701-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FONSECA PAEZ DIANA JULIETH", "normalizedName": "fonseca paez diana julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "701-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GOMEZ ALISSON ARIANA", "normalizedName": "gil gomez alisson ariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "701-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ GOMEZ SAMUEL", "normalizedName": "gomez gomez samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "701-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ PEDREROS SARA VALENTINA", "normalizedName": "gomez pedreros sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "701-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUERRERO LAURENS JAFET DAVID", "normalizedName": "guerrero laurens jafet david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "701-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JAIME QUINTERO SARA SOFIA", "normalizedName": "jaime quintero sara sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "701-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA CEDIEL EDWARD STIVEN", "normalizedName": "lara cediel edward stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "701-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MADRID GARZON MARIA PAULA", "normalizedName": "madrid garzon maria paula"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "701-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NIÑO MALDONADO LUIS MATEO", "normalizedName": "nino maldonado luis mateo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "701-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PARRA BARRERO SAMUEL CRISTOPHER", "normalizedName": "parra barrero samuel cristopher"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "701-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS AREVALO ANGIE LUCERO", "normalizedName": "penagos arevalo angie lucero"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "701-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS VALBUENA DAYANNA SOFIA", "normalizedName": "penagos valbuena dayanna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "701-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINEDA CABUYA PAULA BRIGGIT", "normalizedName": "pineda cabuya paula briggit"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "701-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINEDA QUINTERO SHARIK DANIELA", "normalizedName": "pineda quintero sharik daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "701-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON DIAZ MARTIN EMILIO", "normalizedName": "pinzon diaz martin emilio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "701-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON GORDILLO KAROL DAYANA", "normalizedName": "pinzon gordillo karol dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "701-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO TORRES LOREM DAYANA", "normalizedName": "quintero torres lorem dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "701-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROBAYO BENITEZ VALERIA", "normalizedName": "robayo benitez valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "701-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTAMARIA BECERRA LAURYN NICOLLE", "normalizedName": "santamaria becerra lauryn nicolle"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "701-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SOSA FORERO JORGE STEVEN", "normalizedName": "sosa forero jorge steven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "701-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALBUENA IBAÑEZ SALOME", "normalizedName": "valbuena ibanez salome"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "701-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VARGAS MARIN SARA JINETH", "normalizedName": "vargas marin sara jineth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "701-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VELASQUEZ YEPES MELANIE SHARICK", "normalizedName": "velasquez yepes melanie sharick"}]	t	900100	2026-03-17 15:31:22.326568+01	2026-03-17 15:31:22.326568+01
8	1	\N	7	02	702	7°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 702	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "7°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "702-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO MENESES DANNA ISABELA", "normalizedName": "arevalo meneses danna isabela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "702-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO RIAÑO PAULA ISABELA", "normalizedName": "arevalo riano paula isabela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "702-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO PINZON CAROL VANESSA", "normalizedName": "castro pinzon carol vanessa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "702-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAVARRIO GARZON JUAN JOSE", "normalizedName": "chavarrio garzon juan jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "702-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CORREA GAITAN DIEGO ALEXANDER", "normalizedName": "correa gaitan diego alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "702-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUESTAS CONTRERAS SISLEY DAYANNA", "normalizedName": "cuestas contreras sisley dayanna"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "702-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUFIÑO TORRES SARA VALERIA", "normalizedName": "cufino torres sara valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "702-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FARFAN MARIN JUAN JOSE", "normalizedName": "farfan marin juan jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "702-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FONSECA MENDOZA SADDAN ANDRES", "normalizedName": "fonseca mendoza saddan andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "702-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO MURCIA CAMILO ANDRES", "normalizedName": "forero murcia camilo andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "702-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ LEON VALERIA", "normalizedName": "gomez leon valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "702-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUAPACHA CUEVAS LISETH TATIANA", "normalizedName": "guapacha cuevas liseth tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "702-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUAYAMBUCO ROMERO ELIANA VALERIA", "normalizedName": "guayambuco romero eliana valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "702-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ SANCHEZ MARIA JOSE", "normalizedName": "hernandez sanchez maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "702-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ RODRIGUEZ HILMER STIVEN", "normalizedName": "lopez rodriguez hilmer stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "702-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MELO CASTRO ANA SOFIA", "normalizedName": "melo castro ana sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "702-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MOGOLLON TOBAR JOSHUA DANIEL", "normalizedName": "mogollon tobar joshua daniel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "702-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONROY FERNANDEZ MARTIN ALEJANDRO", "normalizedName": "monroy fernandez martin alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "702-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO CALDERON SHARITH ANTONELLA", "normalizedName": "montenegro calderon sharith antonella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "702-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO CAMELO JUAN DAVID", "normalizedName": "montenegro camelo juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "702-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO DIAZ YEFER JULIAN", "normalizedName": "montenegro diaz yefer julian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "702-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ DIAZ ADRIAN", "normalizedName": "perez diaz adrian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "702-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON PENAGOS JOSE LUIS", "normalizedName": "pinzon penagos jose luis"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "702-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON RODRIGUEZ JUAN MARTIN", "normalizedName": "pinzon rodriguez juan martin"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "702-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUIMBAY RODRIGUEZ WILSON YAMITH", "normalizedName": "quimbay rodriguez wilson yamith"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "702-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROA MARTINEZ JHOAN STIVEN", "normalizedName": "roa martinez jhoan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "702-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ GIL VALERY TATIANA", "normalizedName": "rodriguez gil valery tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "702-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ GOMEZ SERGIO ANDRES", "normalizedName": "rodriguez gomez sergio andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "702-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ MARIN KELLY JAZMIN", "normalizedName": "rodriguez marin kelly jazmin"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "702-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ RAQUIRA HOLMAN ALEXIS", "normalizedName": "rodriguez raquira holman alexis"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "702-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SAAVEDRA MONTENEGRO EMILY JULIETH", "normalizedName": "saavedra montenegro emily julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "702-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SOLER BENAVIDES DANIA VALERIA", "normalizedName": "soler benavides dania valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "702-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SOSA FARFAN SERGIO ANDRES", "normalizedName": "sosa farfan sergio andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "702-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TIQUE ROMERO YAILETH FERNANDA", "normalizedName": "tique romero yaileth fernanda"}]	t	900100	2026-03-17 15:31:22.329857+01	2026-03-17 15:31:22.329857+01
9	1	\N	7	03	703	7°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 703	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "7°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "703-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL IBAGUE JUAN DAVID", "normalizedName": "abril ibague juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "703-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BAUTISTA GUTIERREZ ARANTZA MAGDIEL", "normalizedName": "bautista gutierrez arantza magdiel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "703-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES BENAVIDES JOHAN NICOLAS", "normalizedName": "benavides benavides johan nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "703-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES UMBARILA LAURA VALENTINA", "normalizedName": "benavides umbarila laura valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "703-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BERNAL COMBITA SARA GABRIELA", "normalizedName": "bernal combita sara gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "703-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BERNAL PEÑA MANUEL FELIPE", "normalizedName": "bernal pena manuel felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "703-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAREY LOPEZ SHAIEL MARIANA", "normalizedName": "carey lopez shaiel mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "703-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARO ESPITIA JOSE MIGUEL", "normalizedName": "caro espitia jose miguel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "703-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASALLAS MALDONADO LAURA ISABELLA", "normalizedName": "casallas maldonado laura isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "703-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO AGUILAR BRIYITH XIOMARA", "normalizedName": "castillo aguilar briyith xiomara"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "703-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CETINA ROA JEIMY KATHERIN", "normalizedName": "cetina roa jeimy katherin"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "703-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ SANCHEZ DAVID SANTIAGO", "normalizedName": "cruz sanchez david santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "703-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DIAZ RIAÑO WILLIAM DUVAN", "normalizedName": "diaz riano william duvan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "703-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DONCEL PINZON LUCIANA", "normalizedName": "doncel pinzon luciana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "703-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FERNANDEZ CRUZ SARA LUCIANA", "normalizedName": "fernandez cruz sara luciana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "703-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA RAMIREZ JUAN CAMILO", "normalizedName": "garcia ramirez juan camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "703-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ PASCAGAZA SAMUEL HERNAN", "normalizedName": "gomez pascagaza samuel hernan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "703-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HURTADO PINEDA JOHAN SEBASTIAN", "normalizedName": "hurtado pineda johan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "703-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JIMENEZ CASTAÑEDA SARA VALERIA", "normalizedName": "jimenez castaneda sara valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "703-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA CASTILLO ESNEIDER SANTIAGO", "normalizedName": "lara castillo esneider santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "703-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA VELANDIA ZHARICK TATIANA", "normalizedName": "lara velandia zharick tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "703-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LIS BARBON JHOSEP DAVID", "normalizedName": "lis barbon jhosep david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "703-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ RODRIGUEZ JOHAN ANDRES", "normalizedName": "lopez rodriguez johan andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "703-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARIN ROBAYO JULIAN MAURICIO", "normalizedName": "marin robayo julian mauricio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "703-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PARADA MORA DANNA CAMILA", "normalizedName": "parada mora danna camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "703-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINEDA LÓPEZ JOAN SEBASTIAN", "normalizedName": "pineda lopez joan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "703-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON ABRIL JENNIFER TATIANA", "normalizedName": "pinzon abril jennifer tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "703-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON ACOSTA SHAROL JULIANA", "normalizedName": "pinzon acosta sharol juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "703-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ RODRIGUEZ ALISSON JULIANA", "normalizedName": "ramirez rodriguez alisson juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "703-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ SANCHEZ EDWIN SEBASTIAN", "normalizedName": "ramirez sanchez edwin sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "703-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROJAS TORRES HERNAN ALEJANDRO", "normalizedName": "rojas torres hernan alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "703-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUIZ ALARCON EDDY NIKOLAS", "normalizedName": "ruiz alarcon eddy nikolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "703-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SALCEDO ALVARADO YINNETH SOLANGIE", "normalizedName": "salcedo alvarado yinneth solangie"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "703-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ PACHOTE DILAN ANDRES", "normalizedName": "sanchez pachote dilan andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "703-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES YEPES JUAN DAVID", "normalizedName": "torres yepes juan david"}]	t	900100	2026-03-17 15:31:22.332319+01	2026-03-17 15:31:22.332319+01
10	1	\N	7	04	704	7°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 704	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "7°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "704-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BOLIVAR COMBA JOHAN STEVEN", "normalizedName": "bolivar comba johan steven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "704-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUSTOS LEON ANDRES DAVID", "normalizedName": "bustos leon andres david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "704-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA GARCIA FABIAN ESTEBAN", "normalizedName": "cabuya garcia fabian esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "704-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAPOTE CABUYA JULIETH ESTEFANY", "normalizedName": "capote cabuya julieth estefany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "704-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASALLAS BEJARANO DORIS LILIANA", "normalizedName": "casallas bejarano doris liliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "704-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA VERGAÑO JULIAN SANTIAGO", "normalizedName": "castaneda vergano julian santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "704-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTIBLANCO SANCHEZ KAREN DAYANA", "normalizedName": "castiblanco sanchez karen dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "704-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CORTES LOPEZ KAREN VANESSA", "normalizedName": "cortes lopez karen vanessa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "704-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ CASTILLO JUAN MARTIN", "normalizedName": "gomez castillo juan martin"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "704-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUATAQUIRA FORERO JOHAN SANTIAGO", "normalizedName": "guataquira forero johan santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "704-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUETTE BARANDICA RACHELL SOPHIA", "normalizedName": "guette barandica rachell sophia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "704-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERRERA SUAREZ SARA VALENTINA", "normalizedName": "herrera suarez sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "704-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LATORRE CALLEJAS MICHAEL STEVEN", "normalizedName": "latorre callejas michael steven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "704-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LATORRE CASTILLO LAURA VALENTINA", "normalizedName": "latorre castillo laura valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "704-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LIZARAZO BRICEÑO SARA ISABELLA", "normalizedName": "lizarazo briceno sara isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "704-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARCELO ESTUPIÑAN EILIN NICOLLE", "normalizedName": "marcelo estupinan eilin nicolle"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "704-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NOVA CASTIBLANCO OSCAR GIOVANNY", "normalizedName": "nova castiblanco oscar giovanny"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "704-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NOVA GOMEZ THIAGO MATIAS", "normalizedName": "nova gomez thiago matias"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "704-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ORJUELA LARA DANNA SOFIA", "normalizedName": "orjuela lara danna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "704-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ORTIZ TORRES JESUS ESTEBAN", "normalizedName": "ortiz torres jesus esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "704-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PARRA CAMELO SARA VALERIA", "normalizedName": "parra camelo sara valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "704-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PASCAGAZA AREVALO DAVID LEANDRO", "normalizedName": "pascagaza arevalo david leandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "704-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEDRAZA CABUYA MARIA DE LOS ANGELES", "normalizedName": "pedraza cabuya maria de los angeles"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "704-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ RIOS JAXON ANDRES", "normalizedName": "perez rios jaxon andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "704-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINEDA GOMEZ ANGIE KATHERIN", "normalizedName": "pineda gomez angie katherin"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "704-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PRIMICIERO BENAVIDES MICHAEL ANDRES", "normalizedName": "primiciero benavides michael andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "704-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUIROGA CERON CRISTIAN ESTEBAN", "normalizedName": "quiroga ceron cristian esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "704-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAQUIRA FARFAN JULIAN SANTIAGO", "normalizedName": "raquira farfan julian santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "704-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROA FERNANDEZ JHON SNEIDER", "normalizedName": "roa fernandez jhon sneider"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "704-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ NAVARRO KEVIN JULIAN", "normalizedName": "sanchez navarro kevin julian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "704-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SEGURA CASTILLO JIMMY SAMUEL", "normalizedName": "segura castillo jimmy samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "704-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SERRANO PASCAGAZA JUAN SEBASTIAN", "normalizedName": "serrano pascagaza juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "704-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUAREZ MALAGON KAROL YULIANA", "normalizedName": "suarez malagon karol yuliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "704-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TERREROS MONTENEGRO SARA VALERIA", "normalizedName": "terreros montenegro sara valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "704-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TOMASES OSORIO ABEL TOMAS", "normalizedName": "tomases osorio abel tomas"}]	t	900100	2026-03-17 15:31:22.335574+01	2026-03-17 15:31:22.335574+01
11	1	\N	7	05	705	7°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 705	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "7°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "705-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ALEMAN RODRIGUEZ ANGIE LUCIANA", "normalizedName": "aleman rodriguez angie luciana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "705-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ARIAS SUA JHONNY ALEXANDER", "normalizedName": "arias sua jhonny alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "705-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARAJAS SANGUINO PAULA VALENTINA", "normalizedName": "barajas sanguino paula valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "705-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARATO SANDOVAL JOSEPH MATIAS", "normalizedName": "barato sandoval joseph matias"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "705-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARATO SANDOVAL MANUEL ALEJANDRO", "normalizedName": "barato sandoval manuel alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "705-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRIGA LOTA KAREN YECENNIA", "normalizedName": "barriga lota karen yecennia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "705-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES ARIAS ANDREA JULIETH", "normalizedName": "benavides arias andrea julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "705-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BERNAL CHICA SANDY NATALIA", "normalizedName": "bernal chica sandy natalia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "705-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BOLIVAR GARCIA SARA VALENTINA", "normalizedName": "bolivar garcia sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "705-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA ORJUELA JUAN DAVID", "normalizedName": "cabuya orjuela juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "705-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARDENAS QUINTERO EDWIN SANTIAGO", "normalizedName": "cardenas quintero edwin santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "705-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS VERGEL YEISSON ALEXANDER", "normalizedName": "contreras vergel yeisson alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "705-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ RUEDA LINDA MICHEL", "normalizedName": "cruz rueda linda michel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "705-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ SOSA ANGIE LORENA", "normalizedName": "cruz sosa angie lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "705-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON BARRIGA MARIA CAMILA", "normalizedName": "garzon barriga maria camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "705-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIRALDO TANGUA JUAN DAVID", "normalizedName": "giraldo tangua juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "705-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ RODRIGUEZ DIEGO ALEJANDRO", "normalizedName": "gomez rodriguez diego alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "705-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ UMBARILA IVAN ALEJANDRO", "normalizedName": "gomez umbarila ivan alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "705-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ UMBARILA SAMUEL ALEJANDRO", "normalizedName": "gomez umbarila samuel alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "705-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUERRERO MARTINEZ ENDER JHOSET", "normalizedName": "guerrero martinez ender jhoset"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "705-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ VELASQUEZ BELLA SAMANTA", "normalizedName": "hernandez velasquez bella samanta"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "705-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MELO GOMEZ LINA MARIA", "normalizedName": "melo gomez lina maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "705-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ORJUELA LARA SARA VALENTINA", "normalizedName": "orjuela lara sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "705-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PAEZ CUBILLOS EVELIN DAYAN", "normalizedName": "paez cubillos evelin dayan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "705-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PIRANEQUE BALAGUERA MICHEL ASTRID", "normalizedName": "piraneque balaguera michel astrid"}, {"note": "N II-17", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "705-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PLAZAS MALAGÓN SARA SOFÍA", "normalizedName": "plazas malagon sara sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "705-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUICHE VARGAS MARIA JOSE", "normalizedName": "quiche vargas maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "705-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RINCON PULIDO SAMUEL STIVEN", "normalizedName": "rincon pulido samuel stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "705-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ LOPEZ LEINNY BRIYITH", "normalizedName": "sanchez lopez leinny briyith"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "705-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ LOPEZ LEIVER JOHANY", "normalizedName": "sanchez lopez leiver johany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "705-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ SAENZ DUBAN ESTIBENS", "normalizedName": "sanchez saenz duban estibens"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "705-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ SUBA KAREN DAYANA", "normalizedName": "sanchez suba karen dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "705-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TICORA CHAVES EVELIN SOFIA", "normalizedName": "ticora chaves evelin sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "705-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES DIAZ YEISON SAMUEL", "normalizedName": "torres diaz yeison samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "705-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ GORDILLO ANDRES DAVID Ret II-11", "normalizedName": "ramirez gordillo andres david ret ii 11"}]	t	900100	2026-03-17 15:31:22.338898+01	2026-03-17 15:31:22.338898+01
12	1	\N	7	06	706	7°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 706	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "7°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "706-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ALDANA QUINCHE SERGIO DANIEL", "normalizedName": "aldana quinche sergio daniel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "706-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AGUILLON DURAN BRIYITH XIOMARA", "normalizedName": "aguillon duran briyith xiomara"}, {"note": "N II-18", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "706-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRERO ROMERO EDDY SANTIAGO", "normalizedName": "barrero romero eddy santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "706-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES VILLAGRAN LINA ROCIO", "normalizedName": "benavides villagran lina rocio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "706-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESCOBAR GARZON PAULA ANDREA", "normalizedName": "escobar garzon paula andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "706-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO SANCHEZ ANDRES FELIPE", "normalizedName": "forero sanchez andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "706-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FRANCO RUBIANO DAVID ESTIVEN", "normalizedName": "franco rubiano david estiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "706-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL CASTRO EDISSON GABRIEL", "normalizedName": "gil castro edisson gabriel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "706-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GORDILLO GALEANO OMAR CAMILO", "normalizedName": "gordillo galeano omar camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "706-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUEVARA GUAYAMBUCO JOSETH SANTIAGO", "normalizedName": "guevara guayambuco joseth santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "706-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GULLOSO GARZON JEFERSON ESTEBAN", "normalizedName": "gulloso garzon jeferson esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "706-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ PIÑA MAIREN ALEJANDRA", "normalizedName": "gutierrez pina mairen alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "706-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA SUAREZ ANDREY FELIPE", "normalizedName": "lara suarez andrey felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "706-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ AGUILAR MILTON ESTEBAN", "normalizedName": "lopez aguilar milton esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "706-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOZANO YARA KEVIN ANDRES", "normalizedName": "lozano yara kevin andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "706-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONDRAGON GOMEZ JUAN MANUEL", "normalizedName": "mondragon gomez juan manuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "706-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NARVAEZ MONTIEL ELKIN YADIR", "normalizedName": "narvaez montiel elkin yadir"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "706-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NAVARRETE DAZA WALTER BENITO", "normalizedName": "navarrete daza walter benito"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "706-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON BENAVIDES EDWIN STIVEN", "normalizedName": "pinzon benavides edwin stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "706-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PIRABAN CABUYA KAREN VIVIANA", "normalizedName": "piraban cabuya karen viviana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "706-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PLATA OLAVE NICOL KARINA", "normalizedName": "plata olave nicol karina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "706-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SALAZAR PENAGOS RONALD", "normalizedName": "salazar penagos ronald"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "706-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANABRIA ROJAS DIANA MARCELA", "normalizedName": "sanabria rojas diana marcela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "706-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SEGURA MUÑOZ LEIDY TATIANA", "normalizedName": "segura munoz leidy tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "706-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UCHUVO ROJAS JULIAN DAVID", "normalizedName": "uchuvo rojas julian david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "706-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA MORA DEISY TATIANA", "normalizedName": "umbarila mora deisy tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "706-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA PINZON SARA SOFIA", "normalizedName": "umbarila pinzon sara sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "706-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "YEPES SALAZAR DANIEL SANTIAGO", "normalizedName": "yepes salazar daniel santiago"}]	t	900100	2026-03-17 15:31:22.341393+01	2026-03-17 15:31:22.341393+01
13	1	\N	8	01	801	8°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 801	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "8°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "801-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARAJAS DEAZA JOEL ALEJANDRO", "normalizedName": "barajas deaza joel alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "801-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES PINZON MARIA LUCIA", "normalizedName": "benavides pinzon maria lucia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "801-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA OLAVE PAULA JULIANA", "normalizedName": "cabuya olave paula juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "801-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAICEDO DIAZ JHEREMY STEV", "normalizedName": "caicedo diaz jheremy stev"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "801-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTEBLANCO LOPEZ KAROL GINETH", "normalizedName": "casteblanco lopez karol gineth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "801-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTIBLANCO MALDONADO ANDREA JIMENA", "normalizedName": "castiblanco maldonado andrea jimena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "801-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO BOLIVAR SERGIO ANDRES", "normalizedName": "castro bolivar sergio andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "801-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO CASTRO SINDY JAKELINE", "normalizedName": "castro castro sindy jakeline"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "801-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CORREDOR QUITIAN KEVIN SANTIAGO", "normalizedName": "corredor quitian kevin santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "801-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DEARMAS SANCHEZ SHARIK NICOL", "normalizedName": "dearmas sanchez sharik nicol"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "801-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DURAN MOLINA DYLAN SNEIDER", "normalizedName": "duran molina dylan sneider"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "801-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DURAN MOLINA MICHAEL STIVEN", "normalizedName": "duran molina michael stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "801-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FARFAN SUAREZ SAMUEL DAVID", "normalizedName": "farfan suarez samuel david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "801-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FERNANDEZ CASTRO JESUS DAVID", "normalizedName": "fernandez castro jesus david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "801-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO LARA LAURA VALENTINA", "normalizedName": "forero lara laura valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "801-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GELVES CONTRERAS BRIYITH MARIANA", "normalizedName": "gelves contreras briyith mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "801-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ DIAZ HEIDAN SNEIDER", "normalizedName": "hernandez diaz heidan sneider"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "801-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO PEREZ SARA DANIELA", "normalizedName": "moreno perez sara daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "801-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO QUEVEDO ANGEL NORBEY", "normalizedName": "moreno quevedo angel norbey"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "801-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MUETE ESPITIA THIAGO SAMUEL", "normalizedName": "muete espitia thiago samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "801-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NARANJO GIL DERLY YOHANA", "normalizedName": "naranjo gil derly yohana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "801-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PASCAGAZA CASTILLO BRAYAN SNEIDER", "normalizedName": "pascagaza castillo brayan sneider"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "801-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS DUQUE SAMUEL ANTONIO", "normalizedName": "penagos duque samuel antonio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "801-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS ROJAS ALISSON DANIELA", "normalizedName": "penagos rojas alisson daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "801-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON CHAVES YEISON STIVEN", "normalizedName": "pinzon chaves yeison stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "801-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PRIMICIERO RINCON JUAN PABLO", "normalizedName": "primiciero rincon juan pablo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "801-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PRIMICIERO SANCHEZ ERICA TATIANA", "normalizedName": "primiciero sanchez erica tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "801-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUEVEDO QUEVEDO KAROL MICHEL", "normalizedName": "quevedo quevedo karol michel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "801-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROBAYO SANTAMARÍA JOSUE", "normalizedName": "robayo santamaria josue"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "801-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ LANCHEROS PAULA ANDREA", "normalizedName": "rodriguez lancheros paula andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "801-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ PINZON JUNIOR ANTONIO", "normalizedName": "rodriguez pinzon junior antonio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "801-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROMERO DIAZ LUIS ANDRES", "normalizedName": "romero diaz luis andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "801-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SALAZAR PENAGOS RONALD", "normalizedName": "salazar penagos ronald"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "801-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTAFE BERNAL SARA MANUELA", "normalizedName": "santafe bernal sara manuela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "801-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SIERRA ARENAS SAMUEL THOMAS", "normalizedName": "sierra arenas samuel thomas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 36, "rowId": "801-36", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUA PINZON KEVIN FERNEY", "normalizedName": "sua pinzon kevin ferney"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 37, "rowId": "801-37", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TRUJILLO RAMOS KELEMBURG SLEESH", "normalizedName": "trujillo ramos kelemburg sleesh"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 38, "rowId": "801-38", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA CARDENAS SAMUEL JOSHUA", "normalizedName": "umbarila cardenas samuel joshua"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 39, "rowId": "801-39", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SIERRA ESPINEL ENDER DAVID Ret II-24", "normalizedName": "sierra espinel ender david ret ii 24"}]	t	900100	2026-03-17 15:31:22.343684+01	2026-03-17 15:31:22.343684+01
14	1	\N	8	02	802	8°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 802	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "8°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "802-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO PACHON JHOAN SEBASTIAN", "normalizedName": "arevalo pachon jhoan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "802-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BRICEÑO GARZON JUAN JOSE", "normalizedName": "briceno garzon juan jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "802-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA SEGURA LEIDY JULIANA", "normalizedName": "castaneda segura leidy juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "802-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO FARFAN LIZETH MARISOL", "normalizedName": "castro farfan lizeth marisol"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "802-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO GOMEZ SARA ISABEL", "normalizedName": "castro gomez sara isabel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "802-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CIFUENTES GÁNTIVA CARLOS JACOBO", "normalizedName": "cifuentes gantiva carlos jacobo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "802-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS AGUILAR PAULA VALERIA", "normalizedName": "contreras aguilar paula valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "802-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS RODRIGUEZ DANNA VALENTINA", "normalizedName": "contreras rodriguez danna valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "802-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CORTES VARGAS LUISA MAITHE", "normalizedName": "cortes vargas luisa maithe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "802-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DELGADO RODRIGUEZ DANNA VALENTINA", "normalizedName": "delgado rodriguez danna valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "802-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DEPABLOS GARZON SERGIO JOEL", "normalizedName": "depablos garzon sergio joel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "802-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DIAZ TAPASCO JUAN MANUEL", "normalizedName": "diaz tapasco juan manuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "802-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FARFAN CASTAÑEDA JOHAN NICOLAS", "normalizedName": "farfan castaneda johan nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "802-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO PARRA HEIDY VIVIANA", "normalizedName": "forero parra heidy viviana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "802-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GAMBA YEPES YISEL NATALIA", "normalizedName": "gamba yepes yisel natalia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "802-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON QUICHE ANDRES FELIPE", "normalizedName": "garzon quiche andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "802-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GIL EDISON FERNANDO", "normalizedName": "gil gil edison fernando"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "802-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ TORRES BREINER ALEXANDER", "normalizedName": "gomez torres breiner alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "802-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOTTA BENAVIDES HEIDY STEFANIA", "normalizedName": "lotta benavides heidy stefania"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "802-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO GIL KARLA ISABELLA", "normalizedName": "montenegro gil karla isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "802-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO RODRIGUEZ LUIS FERNANDO", "normalizedName": "montenegro rodriguez luis fernando"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "802-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO CHAVES KEVIN SANTIAGO", "normalizedName": "moreno chaves kevin santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "802-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MUÑOZ COBOS ERICK SAMUEL", "normalizedName": "munoz cobos erick samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "802-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NIÑO MALDONADO JUAN DAVID", "normalizedName": "nino maldonado juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "802-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ORTIZ BARRETO LAURA SOFIA", "normalizedName": "ortiz barreto laura sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "802-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PACHON PINZON DULCE MARIA", "normalizedName": "pachon pinzon dulce maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "802-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ VELANDIA KEVIN MAURICIO", "normalizedName": "perez velandia kevin mauricio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "802-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON CASTAÑEDA ERIKA TATIANA", "normalizedName": "pinzon castaneda erika tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "802-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON SANCHEZ LAURA FERNANDA", "normalizedName": "pinzon sanchez laura fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "802-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ LOPEZ YOVANY SAMUEL", "normalizedName": "ramirez lopez yovany samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "802-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RINCON MORENO DIEGO JOSE", "normalizedName": "rincon moreno diego jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "802-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIOS ALVAREZ SHARON GISSETH", "normalizedName": "rios alvarez sharon gisseth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "802-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROMERO JIMENEZ JULIANA VALENTINA", "normalizedName": "romero jimenez juliana valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "802-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANABRIA VERA JUANA VALENTINA", "normalizedName": "sanabria vera juana valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "802-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTOS ROMERO MARTIN FELIPE", "normalizedName": "santos romero martin felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 36, "rowId": "802-36", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SOLER PIÑEROS DEIVID ALEJANDRO", "normalizedName": "soler pineros deivid alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 37, "rowId": "802-37", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES BOLIVAR JULIAN ESTEBAN", "normalizedName": "torres bolivar julian esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 38, "rowId": "802-38", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES RAMIREZ NICOLAS ALEXANDER", "normalizedName": "torres ramirez nicolas alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 39, "rowId": "802-39", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA HERRRERA NIKOL MARIANA", "normalizedName": "zamora herrrera nikol mariana"}]	t	900100	2026-03-17 15:31:22.346515+01	2026-03-17 15:31:22.346515+01
15	1	\N	8	03	803	8°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 803	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "8°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "803-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL CASALLAS OMAR IVAN", "normalizedName": "abril casallas omar ivan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "803-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL GOMEZ JIMY FABIAN", "normalizedName": "abril gomez jimy fabian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "803-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AGUILAR BUSTOS EMMANUEL JOAN", "normalizedName": "aguilar bustos emmanuel joan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "803-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AGUILAR MOLINA ASTRID LORENA", "normalizedName": "aguilar molina astrid lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "803-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ALDANA SARMIENTO JUAN JOSE", "normalizedName": "aldana sarmiento juan jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "803-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ARANDIA SANCHEZ LAURA CAMILA", "normalizedName": "arandia sanchez laura camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "803-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARAJAS CUBILLOS JENNIFER NATALIA", "normalizedName": "barajas cubillos jennifer natalia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "803-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRERO PRIETO JOHAN DAVID", "normalizedName": "barrero prieto johan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "803-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAÑON CABUYA MARIA JOSE", "normalizedName": "canon cabuya maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "803-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARDENAS ACEVEDO CRISTOPHER AARON", "normalizedName": "cardenas acevedo cristopher aaron"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "803-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO MAYORGA JULIAN ALEXIS", "normalizedName": "castro mayorga julian alexis"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "803-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CATAÑO BECERRA MARIANA MICHEL", "normalizedName": "catano becerra mariana michel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "803-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CEPEDA RAMIREZ IO", "normalizedName": "cepeda ramirez io"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "803-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FLOREZ RODRIGUEZ SARA LIZETH", "normalizedName": "florez rodriguez sara lizeth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "803-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON GARZON KEVIN ALEJANDRO", "normalizedName": "garzon garzon kevin alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "803-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ UMBARILA MARIA JOSE", "normalizedName": "gomez umbarila maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "803-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUALTEROS CASALLAS YEIMY KATERINE", "normalizedName": "gualteros casallas yeimy katerine"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "803-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUALTEROS CASTRO FREDY YESID", "normalizedName": "gualteros castro fredy yesid"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "803-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUEVARA SOSA BREYNER EDUARDO", "normalizedName": "guevara sosa breyner eduardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "803-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JIMENEZ BONZA SARA LUCIA", "normalizedName": "jimenez bonza sara lucia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "803-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LAVADO SARMIENTO DANA VERONICA", "normalizedName": "lavado sarmiento dana veronica"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "803-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MEDINA TOVAR ANA SOFIA", "normalizedName": "medina tovar ana sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "803-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO CASTAÑEDA ANGEL NICOLAS", "normalizedName": "moreno castaneda angel nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "803-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO CASTRO IVONNE SOFIA", "normalizedName": "moreno castro ivonne sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "803-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NAVARRETE SUAREZ KAROL TATIANA", "normalizedName": "navarrete suarez karol tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "803-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NAVARRO MURCIA JHOAN EMANUEL", "normalizedName": "navarro murcia jhoan emanuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "803-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NIEL CRUZ GABRIELA", "normalizedName": "niel cruz gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "803-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS CASTAÑEDA LAURA JULIANA", "normalizedName": "penagos castaneda laura juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "803-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINEDA GOMEZ YESSICA MARCELA", "normalizedName": "pineda gomez yessica marcela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "803-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PRIMICIERO RODRIGUEZ SAMUEL EMILIO", "normalizedName": "primiciero rodriguez samuel emilio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "803-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUEVEDO SARMIENTO JOHAN FERNEY", "normalizedName": "quevedo sarmiento johan ferney"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "803-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROCHA PEREZ JADE NAIARA", "normalizedName": "rocha perez jade naiara"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "803-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUBIO MONTENEGRO EMELY YURANY", "normalizedName": "rubio montenegro emely yurany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "803-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUBIO RODRIGUEZ TANIA JULIETH", "normalizedName": "rubio rodriguez tania julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "803-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANABRIA SUBA LAURA MARIANA", "normalizedName": "sanabria suba laura mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 36, "rowId": "803-36", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA MONTENEGRO JULIAN STEVEN", "normalizedName": "umbarila montenegro julian steven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 37, "rowId": "803-37", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "URIBE ROMERO NICOL CATHERINE", "normalizedName": "uribe romero nicol catherine"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 38, "rowId": "803-38", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VERGARA DAZA KAREN TATIANA", "normalizedName": "vergara daza karen tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 39, "rowId": "803-39", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA CAMELO SAMUEL FELIPE", "normalizedName": "zamora camelo samuel felipe"}]	t	900100	2026-03-17 15:31:22.348827+01	2026-03-17 15:31:22.348827+01
16	1	\N	8	04	804	8°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 804	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "8°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "804-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL RIAÑO SAMUEL ALEJANDRO", "normalizedName": "abril riano samuel alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "804-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO BUITRAGO ERIKA TATIANA", "normalizedName": "arevalo buitrago erika tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "804-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO BUITRAGO IVAN SANTIAGO", "normalizedName": "arevalo buitrago ivan santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "804-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BOLIVAR CHAPARRO IVAN ANDRES", "normalizedName": "bolivar chaparro ivan andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "804-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CALDERON TORRES DEISY DANIELA", "normalizedName": "calderon torres deisy daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "804-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAMELO ROMERO SARAI MICHEL", "normalizedName": "camelo romero sarai michel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "804-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAÑON MURCIA TALIANA GUADALUPE", "normalizedName": "canon murcia taliana guadalupe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "804-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO LOPEZ KEVIN ALEXANDER", "normalizedName": "castillo lopez kevin alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "804-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO MARTINEZ DENNIS YORLADY", "normalizedName": "castro martinez dennis yorlady"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "804-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ CANO ADRIANA JULIETH", "normalizedName": "cruz cano adriana julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "804-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ HEREDIA HANNA LIZBETH", "normalizedName": "cruz heredia hanna lizbeth"}, {"note": "N II-25", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "804-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUBILLOS MORA PABLO ANDRÉS", "normalizedName": "cubillos mora pablo andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "804-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUESTAS JIMENEZ FAYMAN STIVEN", "normalizedName": "cuestas jimenez fayman stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "804-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUEVAS RODRIGUEZ KAREN DAYANA", "normalizedName": "cuevas rodriguez karen dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "804-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO MURCIA ZAYRA NATHALIE", "normalizedName": "forero murcia zayra nathalie"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "804-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA BUSTOS SHARIT MICHELLE", "normalizedName": "garcia bustos sharit michelle"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "804-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL LOPEZ KEILER YESID", "normalizedName": "gil lopez keiler yesid"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "804-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ BOHORQUEZ EIMER SANTIAGO", "normalizedName": "gomez bohorquez eimer santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "804-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ RAMIREZ KEVIN DAVID", "normalizedName": "gomez ramirez kevin david"}, {"note": "N II-9", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "804-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUALTEROS MAYORGA ALISSON", "normalizedName": "gualteros mayorga alisson"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "804-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LANCHEROS GONZALEZ SHARON JULIANA", "normalizedName": "lancheros gonzalez sharon juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "804-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MELO GUZMAN LINA GABRIELA", "normalizedName": "melo guzman lina gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "804-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ORJUELA LEON YIBETH VALERIA", "normalizedName": "orjuela leon yibeth valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "804-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ORTIZ MORA DAIRAN CAMILA", "normalizedName": "ortiz mora dairan camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "804-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OSPINA SANCHEZ JORGE LORENZO", "normalizedName": "ospina sanchez jorge lorenzo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "804-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OTALORA LEÓN KAREN VALENTINA", "normalizedName": "otalora leon karen valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "804-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PACHON CASALLAS JOSE EMILIANO", "normalizedName": "pachon casallas jose emiliano"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "804-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS ESCOBEDO CARLOS ARTURO", "normalizedName": "penagos escobedo carlos arturo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "804-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEÑA VALERO DANIEL SANTIAGO", "normalizedName": "pena valero daniel santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "804-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ RAMOS LUIS MIGUEL", "normalizedName": "perez ramos luis miguel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "804-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON VILLAGRAN FLOR EMILSE", "normalizedName": "pinzon villagran flor emilse"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "804-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PULIDO RIAÑO DANNA GUADALUPE", "normalizedName": "pulido riano danna guadalupe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "804-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROBAYO PINZON DEISY LILIANA", "normalizedName": "robayo pinzon deisy liliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "804-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ UMBARILA EMANUEL", "normalizedName": "rodriguez umbarila emanuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "804-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANABRIA SEGURA DIANA VALENTINA", "normalizedName": "sanabria segura diana valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 36, "rowId": "804-36", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUA QUINTERO ZAIDA VALENTINA", "normalizedName": "sua quintero zaida valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 37, "rowId": "804-37", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TELLEZ BERNAL MARIA ALEJANDRA", "normalizedName": "tellez bernal maria alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 38, "rowId": "804-38", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES SARMIENTO KAREN SOFIA", "normalizedName": "torres sarmiento karen sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 39, "rowId": "804-39", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TRUJILLO ALFONSO NICOLLE ISABELLA", "normalizedName": "trujillo alfonso nicolle isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 40, "rowId": "804-40", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA CONTRERAS SHAIRA YIBETH", "normalizedName": "umbarila contreras shaira yibeth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 41, "rowId": "804-41", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA MORA DIEGO JULIAN", "normalizedName": "zamora mora diego julian"}]	t	900100	2026-03-17 15:31:22.35153+01	2026-03-17 15:31:22.35153+01
17	1	\N	8	05	805	8°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 805	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "8°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "805-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AVILA OYOLA YEISSON STIVEN", "normalizedName": "avila oyola yeisson stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "805-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BORDA SOSA ERIC SANTIAGO", "normalizedName": "borda sosa eric santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "805-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUITRAGO PINEDA CIELO BALENTINA", "normalizedName": "buitrago pineda cielo balentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "805-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARPINTERO CARDENAS JUAN NICOLAS", "normalizedName": "carpintero cardenas juan nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "805-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASALLAS SOSA CRISTIAN YAIR", "normalizedName": "casallas sosa cristian yair"}, {"note": "N III-4", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "805-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA RAMIREZ LUCIANA", "normalizedName": "castaneda ramirez luciana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "805-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTIBLANCO VARGAS EDWIN JHOJANES", "normalizedName": "castiblanco vargas edwin jhojanes"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "805-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CETINA CHAVES HERNAN STIVEN", "normalizedName": "cetina chaves hernan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "805-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUESTA MORA WENDY LORENA", "normalizedName": "cuesta mora wendy lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "805-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESPITIA CHACON YEFERSON ESTEBAN", "normalizedName": "espitia chacon yeferson esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "805-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FERNANDEZ PRIMICIERO MARIANA VALENTINA", "normalizedName": "fernandez primiciero mariana valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "805-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO BARON JUAN SEBASTIAN", "normalizedName": "forero baron juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "805-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GALEANO OSORIO SARA ALEJANDRA", "normalizedName": "galeano osorio sara alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "805-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON TORRES ANDERSSON STIVEN", "normalizedName": "garzon torres andersson stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "805-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ CUELLAR PAULA ANAHÍ", "normalizedName": "hernandez cuellar paula anahi"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "805-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ INFANTE XIOMARA ANDREA", "normalizedName": "hernandez infante xiomara andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "805-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ VALENCIA ANDRES DAVID", "normalizedName": "hernandez valencia andres david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "805-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ GOMEZ MAIKELL ANDRES", "normalizedName": "lopez gomez maikell andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "805-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ YEPES DIEGO ALEXANDER", "normalizedName": "lopez yepes diego alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "805-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARTINEZ DOZA ANDERSON ANDREY", "normalizedName": "martinez doza anderson andrey"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "805-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARTINEZ GUATAQUIRA SARA JULIETH", "normalizedName": "martinez guataquira sara julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "805-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MENDOZA VALERIANO SHAROL NAOMY", "normalizedName": "mendoza valeriano sharol naomy"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "805-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONROY GIL SAMY JELIXA", "normalizedName": "monroy gil samy jelixa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "805-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NARANJO GUACANEME JULIETH TATIANA", "normalizedName": "naranjo guacaneme julieth tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "805-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OJEDA BENITO DANNA SOFIA", "normalizedName": "ojeda benito danna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "805-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OYOLA TOLOZA JEIMY LORENA", "normalizedName": "oyola toloza jeimy lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "805-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PARADA PACHON SARA VALENTINA", "normalizedName": "parada pachon sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "805-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ DIAZ DERIAN", "normalizedName": "perez diaz derian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "805-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROMERO RUBIANO KAREN VIVIANA", "normalizedName": "romero rubiano karen viviana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "805-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SALAZAR VILLA JUAN PABLO", "normalizedName": "salazar villa juan pablo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "805-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SEGURA FARFAN JAVIER SANTIAGO", "normalizedName": "segura farfan javier santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "805-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SIATOYA GUTIERREZ ANTONY STIVEN", "normalizedName": "siatoya gutierrez antony stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "805-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SILVA BARRIGA LAURA VALENTINA", "normalizedName": "silva barriga laura valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "805-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUA CAMARGO BRENDA YULIETH", "normalizedName": "sua camargo brenda yulieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "805-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUAREZ HENAO ASLHY LORENA", "normalizedName": "suarez henao aslhy lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 36, "rowId": "805-36", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA LAMPREA CRISTIAM CAMILO", "normalizedName": "umbarila lamprea cristiam camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 37, "rowId": "805-37", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALBUENA SUAREZ DANNA GABRIELA", "normalizedName": "valbuena suarez danna gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 38, "rowId": "805-38", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALBUENA SUAREZ MARIA ISABELA", "normalizedName": "valbuena suarez maria isabela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 39, "rowId": "805-39", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VELANDIA SUAREZ LUZ MARIA", "normalizedName": "velandia suarez luz maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 40, "rowId": "805-40", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA DIAZ SARAY VANESA", "normalizedName": "zamora diaz saray vanesa"}]	t	900100	2026-03-17 15:31:22.355593+01	2026-03-17 15:31:22.355593+01
18	1	1	9	01	901	9°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 901	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "9°", "subjectName": "", "teacherName": "", "classGroupId": 1, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "901-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ACOSTA TIGUAQUE SARA YULIETH", "normalizedName": "acosta tiguaque sara yulieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "901-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO GOMEZ HOLLMAN DAVID", "normalizedName": "arevalo gomez hollman david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "901-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BELLO GONZALES YINNA ESPERANZA", "normalizedName": "bello gonzales yinna esperanza"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "901-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUITRAGO PINEDA JOEL SANTIAGO", "normalizedName": "buitrago pineda joel santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "901-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA SALGADO SHAROL NICOL", "normalizedName": "cabuya salgado sharol nicol"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "901-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO PENAGOS CARLOS EDUARDO", "normalizedName": "castro penagos carlos eduardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "901-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAPARRO PINZON LUIS SANTIAGO", "normalizedName": "chaparro pinzon luis santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "901-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL BRICEÑO NICOLL TATIANA", "normalizedName": "gil briceno nicoll tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "901-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GORDO RODRIGUEZ LIZETH KARINA", "normalizedName": "gordo rodriguez lizeth karina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "901-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ LATORRE JURNHEY DANIELA", "normalizedName": "hernandez latorre jurnhey daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "901-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JIMENEZ BUITRAGO WILSON DUVAN", "normalizedName": "jimenez buitrago wilson duvan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "901-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA SUAREZ SHARID DANIELA", "normalizedName": "lara suarez sharid daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "901-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ ABRIL ANGIE LORENA", "normalizedName": "lopez abril angie lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "901-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ CONTRERAS ASCHLY NICOLL DANIELA", "normalizedName": "lopez contreras aschly nicoll daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "901-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ GALLARDO ORIANNY LISMAR", "normalizedName": "lopez gallardo orianny lismar"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "901-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALDONADO GIL BRITHANY TATIANA", "normalizedName": "maldonado gil brithany tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "901-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO GOMEZ TANIA VALENTINA", "normalizedName": "montenegro gomez tania valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "901-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NEIRA GOMEZ SARA CAMILA", "normalizedName": "neira gomez sara camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "901-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OCHOA CALDERON DANIEL STIVEN", "normalizedName": "ochoa calderon daniel stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "901-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PASCAGAZA MELO JOSEPH MATEO", "normalizedName": "pascagaza melo joseph mateo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "901-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON PASCAGAZA EDWARD SANTIAGO", "normalizedName": "pinzon pascagaza edward santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "901-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROA MOYA SARA", "normalizedName": "roa moya sara"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "901-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ MORENO LAURA SOFIA", "normalizedName": "rodriguez moreno laura sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "901-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ SARMIENTO ANDRES FELIPE", "normalizedName": "rodriguez sarmiento andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "901-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTAMARIA BECERRA SHARIT MARCELA", "normalizedName": "santamaria becerra sharit marcela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "901-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTAMARIA ESPITIA MARIANA ALEJANDRA", "normalizedName": "santamaria espitia mariana alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "901-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES HORMAZA JUAN ESTEBAN", "normalizedName": "torres hormaza juan esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "901-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA PINZON NUBIA ESPERANZA", "normalizedName": "umbarila pinzon nubia esperanza"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "901-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VELOZA GOMEZ JUAN DAVID", "normalizedName": "veloza gomez juan david"}]	t	900100	2026-03-17 15:31:22.358073+01	2026-03-17 15:31:22.358073+01
19	1	2	9	02	902	9°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 902	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "9°", "subjectName": "", "teacherName": "", "classGroupId": 2, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "902-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ARANDA RODRIGUEZ JULIAN ANDRES", "normalizedName": "aranda rodriguez julian andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "902-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BALLEN QUINTERO JENNIFER ANDREA", "normalizedName": "ballen quintero jennifer andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "902-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUITRAGO PINEDA KATHERIN MARIANA", "normalizedName": "buitrago pineda katherin mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "902-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARO PORTACIO SHEYLA XIOMARA", "normalizedName": "caro portacio sheyla xiomara"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "902-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASALLAS VALBUENA MAILY SOFIA", "normalizedName": "casallas valbuena maily sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "902-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA FARFAN KAROL SOFIA", "normalizedName": "castaneda farfan karol sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "902-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTIBLANCO CASTAÑEDA SERGIO ALEJANDRO", "normalizedName": "castiblanco castaneda sergio alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "902-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CIFUENTES BARRERO JHOANN SEBASTIAN", "normalizedName": "cifuentes barrero jhoann sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "902-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS MERCADO VALENTINA MATILDE", "normalizedName": "contreras mercado valentina matilde"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "902-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ MEDINA KAREN JULIANA", "normalizedName": "cruz medina karen juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "902-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DIAZ MEDINA LINA FERNANDA", "normalizedName": "diaz medina lina fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "902-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DOMINGUEZ RODRIGUEZ LAURA VALENTINA", "normalizedName": "dominguez rodriguez laura valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "902-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FERNANDEZ PINZON GABRIELA", "normalizedName": "fernandez pinzon gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "902-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON CASTRO DAVID SANTIAGO", "normalizedName": "garzon castro david santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "902-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL AREVALO HEIDY CONSTANZA", "normalizedName": "gil arevalo heidy constanza"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "902-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUALTEROS ZAMORA JUAN ELIAS", "normalizedName": "gualteros zamora juan elias"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "902-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ CASTRO LAURA YULIANA", "normalizedName": "gutierrez castro laura yuliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "902-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ RAMIREZ JHONATAN DAVID", "normalizedName": "gutierrez ramirez jhonatan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "902-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HORTUA GONZALEZ JUANA VALENTINA", "normalizedName": "hortua gonzalez juana valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "902-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MAYORGA GARZON LAURA JULIANA", "normalizedName": "mayorga garzon laura juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "902-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MEDINA LIZARAZO JHONATAN CAMILO", "normalizedName": "medina lizarazo jhonatan camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "902-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OJEDA GARZON SERGIO ALEJANDRO", "normalizedName": "ojeda garzon sergio alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "902-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PERALTA GARCIA JOHEL SANTIAGO", "normalizedName": "peralta garcia johel santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "902-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON PENAGOS LAURA VALENTINA", "normalizedName": "pinzon penagos laura valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "902-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PIRANEQUE BALAGUERA PAULA ANDREA", "normalizedName": "piraneque balaguera paula andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "902-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PRIETO LOPEZ TANIA VALENTINA", "normalizedName": "prieto lopez tania valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "902-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PUENTES RODRIGUEZ JULIANA MARIA", "normalizedName": "puentes rodriguez juliana maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "902-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUETE MAMANCHE LAURA MARIA", "normalizedName": "quete mamanche laura maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "902-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIAÑO BENAVIDES LEIDY PATRICIA", "normalizedName": "riano benavides leidy patricia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "902-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROJAS CUESTO JHOHAN ANDRES", "normalizedName": "rojas cuesto jhohan andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "902-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ RODRIGUEZ MANUELA ALEJANDRA", "normalizedName": "sanchez rodriguez manuela alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "902-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SARMIENTO GORDILLO HANNA SALOME", "normalizedName": "sarmiento gordillo hanna salome"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "902-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUA GUAQUETA HAROLD STIVEN", "normalizedName": "sua guaqueta harold stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "902-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUESCA PINEDA DANNA ISABELLA", "normalizedName": "suesca pineda danna isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "902-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TAPASCO QUEVEDO LADY DAHIANA", "normalizedName": "tapasco quevedo lady dahiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 36, "rowId": "902-36", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES GIL LAURA DANIELA", "normalizedName": "torres gil laura daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 37, "rowId": "902-37", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "URUEÑA AGUILAR JULIANA SOPHIA", "normalizedName": "uruena aguilar juliana sophia"}]	t	900100	2026-03-17 15:31:22.360392+01	2026-03-17 15:31:22.360392+01
20	1	3	9	03	903	9°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 903	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "9°", "subjectName": "", "teacherName": "", "classGroupId": 3, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "903-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL CASTILLO DANNA NICOLE", "normalizedName": "abril castillo danna nicole"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "903-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ALDANA CASTAÑEDA JULIETH ANDREA", "normalizedName": "aldana castaneda julieth andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "903-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRERO SARMIENTO CRISTIAN DAVID", "normalizedName": "barrero sarmiento cristian david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "903-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BOLIVAR CHAPARRO EDWAR STIVEN", "normalizedName": "bolivar chaparro edwar stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "903-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CADENA MUÑOZ MARIA VALENTINA", "normalizedName": "cadena munoz maria valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "903-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAMACHO FERNANDEZ CAMILA ANDREA", "normalizedName": "camacho fernandez camila andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "903-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA ARCHILA VALENTINA", "normalizedName": "castaneda archila valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "903-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO MORA DIANA CAROLINA", "normalizedName": "castro mora diana carolina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "903-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CIFUENTES RODRIGUEZ KARLY KRISTELL", "normalizedName": "cifuentes rodriguez karly kristell"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "903-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "COLORADO BENITEZ LUIS ALEJANDRO", "normalizedName": "colorado benitez luis alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "903-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DIAZ GUEVARA JOSE GABRIEL", "normalizedName": "diaz guevara jose gabriel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "903-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DURAN VILLALOBOS MARIANA", "normalizedName": "duran villalobos mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "903-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FARFAN FERNANDEZ CRISTAL VANESSA", "normalizedName": "farfan fernandez cristal vanessa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "903-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ GOMEZ DUVAN ALEXANDER", "normalizedName": "gomez gomez duvan alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "903-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUEVARA BERNAL KEVIN SAMUEL", "normalizedName": "guevara bernal kevin samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "903-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ BOJACA MARIANA ANDREA", "normalizedName": "lopez bojaca mariana andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "903-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ CORDOBA SAMANTHA", "normalizedName": "lopez cordoba samantha"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "903-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ PRIMICIERO MARIA SALOME", "normalizedName": "lopez primiciero maria salome"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "903-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MANCERA ABRIL DANNA CAMILA", "normalizedName": "mancera abril danna camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "903-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORALES SANCHEZ VANESA ABIGAIL", "normalizedName": "morales sanchez vanesa abigail"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "903-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO QUIROGA JENNIFER SUSANA", "normalizedName": "moreno quiroga jennifer susana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "903-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MUÑOZ NOVOA ANDRES FELIPE", "normalizedName": "munoz novoa andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "903-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OCHOA PINZON PAULA GABRIELA", "normalizedName": "ochoa pinzon paula gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "903-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PAEZ CUBILLOS JOHAN ESTIBEN", "normalizedName": "paez cubillos johan estiben"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "903-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEDRAZA CABUYA JAVIER FELIPE", "normalizedName": "pedraza cabuya javier felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "903-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON GARZON ANDRES FELIPE", "normalizedName": "pinzon garzon andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "903-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON PRIMICIERO LAURA VALERIA", "normalizedName": "pinzon primiciero laura valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "903-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON PULIDO LUISA FERNANDA", "normalizedName": "pinzon pulido luisa fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "903-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PRIMICIERO MURCIA SAMUEL", "normalizedName": "primiciero murcia samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "903-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUBIANO CRUZ MARIA JOSE", "normalizedName": "rubiano cruz maria jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "903-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SAAVEDRA LADINO KAROL TATIANA", "normalizedName": "saavedra ladino karol tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "903-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SALCEDO AREVALO NIKOLL SARAY", "normalizedName": "salcedo arevalo nikoll saray"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "903-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SILVA SUAREZ SARA MICHELLE", "normalizedName": "silva suarez sara michelle"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "903-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UCHUVO RIAÑO JUAN JERONIMO", "normalizedName": "uchuvo riano juan jeronimo"}, {"note": "N III-2", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "903-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "YOPASA ROMERO ANGEL DAVID", "normalizedName": "yopasa romero angel david"}]	t	900100	2026-03-17 15:31:22.36305+01	2026-03-17 15:31:22.36305+01
21	1	4	9	04	904	9°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 904	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "9°", "subjectName": "", "teacherName": "", "classGroupId": 4, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "904-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AGUILAR TORRES SOLANGELEE ESTRELLA", "normalizedName": "aguilar torres solangelee estrella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "904-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRIGA MALAGON BRAYAN ANDRES", "normalizedName": "barriga malagon brayan andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "904-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BEJARANO CASALLAS WENDY CAROLINA", "normalizedName": "bejarano casallas wendy carolina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "904-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BELTRAN LINARES VALERIE FERNANDA", "normalizedName": "beltran linares valerie fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "904-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BOLIVAR FARFAN LAURA FERNANDA", "normalizedName": "bolivar farfan laura fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "904-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO BENAVIDES WENDY YUSLENY", "normalizedName": "castro benavides wendy yusleny"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "904-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CAVIEDES PITA LUISA FERNANDA", "normalizedName": "caviedes pita luisa fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "904-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHIGUACHI SUAREZ SARA VALERIA", "normalizedName": "chiguachi suarez sara valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "904-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CIRCA PINZON JUAN DAVID", "normalizedName": "circa pinzon juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "904-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUEVAS CAMELO JOHAN ALEXIS", "normalizedName": "cuevas camelo johan alexis"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "904-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DONCEL PINZON DANIEL ESTEBAN", "normalizedName": "doncel pinzon daniel esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "904-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FERNANDEZ NAVARRETE CAMILO ANDRES", "normalizedName": "fernandez navarrete camilo andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "904-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GALVIS PEREZ CARLOS SANTIAGO", "normalizedName": "galvis perez carlos santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "904-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GOMEZ FABIO ANDREY", "normalizedName": "gil gomez fabio andrey"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "904-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ AREVALO MARIA ISABEL", "normalizedName": "gomez arevalo maria isabel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "904-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GONZALEZ ROBAYO KAROL TATIANA", "normalizedName": "gonzalez robayo karol tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "904-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GONZALEZ RUIZ MARIA ALEJANDRA", "normalizedName": "gonzalez ruiz maria alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "904-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUALTEROS CASTRO YESSICA GINETH", "normalizedName": "gualteros castro yessica gineth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "904-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUEVARA PARRA MARIA PAULA", "normalizedName": "guevara parra maria paula"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "904-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HURTADO BUENO MIGUEL ANGEL", "normalizedName": "hurtado bueno miguel angel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "904-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ QUINTERO EIDY VANESSA", "normalizedName": "lopez quintero eidy vanessa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "904-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MEJIA RAMIREZ JOSTIN CAMILO", "normalizedName": "mejia ramirez jostin camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "904-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MURCIA BERNAL MICHELLE CAMILA", "normalizedName": "murcia bernal michelle camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "904-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OYOLA ARENAS SARITH NATALIA", "normalizedName": "oyola arenas sarith natalia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "904-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON BENAVIDES MAICOL FERNANDO", "normalizedName": "pinzon benavides maicol fernando"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "904-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIAÑO GUTIERREZ JOHAN CAMILO", "normalizedName": "riano gutierrez johan camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "904-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIVERA PINEDA JULIETTE DAYANA", "normalizedName": "rivera pineda juliette dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "904-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUBIANO JIMENEZ EDDY ALEXANDER", "normalizedName": "rubiano jimenez eddy alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "904-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ CABUYA OSCAR SANTIAGO", "normalizedName": "sanchez cabuya oscar santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "904-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ MONTENEGRO JAVIER ESTHEBAN", "normalizedName": "sanchez montenegro javier estheban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "904-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SEGURA PARRA DANNY ALEJANDRO", "normalizedName": "segura parra danny alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "904-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TRIANA CASALLAS ANGEL SANTIAGO", "normalizedName": "triana casallas angel santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "904-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TUMAY GOMEZ MARLON DE JESUS", "normalizedName": "tumay gomez marlon de jesus"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "904-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA RAMIREZ ANDRES SANTIAGO", "normalizedName": "umbarila ramirez andres santiago"}]	t	900100	2026-03-17 15:31:22.365406+01	2026-03-17 15:31:22.365406+01
22	1	\N	10	01	1001	10°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1001	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "10°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1001-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA BALLEN OSCAR JAVIER", "normalizedName": "cabuya ballen oscar javier"}, {"note": "Viene de 1003", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1001-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARDENAS LEON MICHAEL SANTIAGO", "normalizedName": "cardenas leon michael santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1001-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA LAMPREA EDGAR JAVIER", "normalizedName": "castaneda lamprea edgar javier"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1001-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA MURILLO DANNA ISABELLA", "normalizedName": "castaneda murillo danna isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1001-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA PENAGOS KAREN TATIANA", "normalizedName": "castaneda penagos karen tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1001-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA QUINTERO KAROL ESTEFANIA", "normalizedName": "castaneda quintero karol estefania"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1001-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO PENAGOS KAREN DAYANA", "normalizedName": "castro penagos karen dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1001-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRISTANCHO PINZON LUCIANA FIORELLA", "normalizedName": "cristancho pinzon luciana fiorella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1001-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ FERNANDEZ ZHARICK DANIELA", "normalizedName": "cruz fernandez zharick daniela"}, {"note": "Viene de 1003", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1001-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUASPUD CABUYA CRISTHIAN CAMILO", "normalizedName": "cuaspud cabuya cristhian camilo"}, {"note": "Viene de 1003", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1001-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DIAZ TAPASCO LUIS MATEO", "normalizedName": "diaz tapasco luis mateo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1001-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESPITIA BURGOS LAURA CRISTINA", "normalizedName": "espitia burgos laura cristina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1001-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO MURCIA NICOL ASTRID", "normalizedName": "forero murcia nicol astrid"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1001-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON PRIMICIERO LAURA ALEJANDRA", "normalizedName": "garzon primiciero laura alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1001-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ PAZCAGAZA DEISY ALEJANDRA", "normalizedName": "gomez pazcagaza deisy alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1001-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ PINZON JENNIFER TATIANA", "normalizedName": "gomez pinzon jennifer tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1001-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ CAMELO KAREN JULIETH", "normalizedName": "gutierrez camelo karen julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1001-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "INFANTE PRIMICIERO SEBASTIAN", "normalizedName": "infante primiciero sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1001-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JIMENEZ GOMEZ KAROL STEFANY", "normalizedName": "jimenez gomez karol stefany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1001-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON CORCHUELO OSCAR ALEJANDRO", "normalizedName": "malagon corchuelo oscar alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1001-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON SANCHEZ GRACE IVETTE", "normalizedName": "malagon sanchez grace ivette"}, {"note": "Viene de 1003", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1001-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MEDRANO SANCHEZ YANIS JOHANA", "normalizedName": "medrano sanchez yanis johana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1001-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTERO LOTTA SARA VALERIA", "normalizedName": "montero lotta sara valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1001-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA MORA YESSICA MILENA", "normalizedName": "mora mora yessica milena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1001-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OVIEDO SEGURA ISABELLA", "normalizedName": "oviedo segura isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1001-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ TORRES DENNIS RAKEEL", "normalizedName": "perez torres dennis rakeel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1001-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ CORREA DANNA VALERIA", "normalizedName": "ramirez correa danna valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1001-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ FARFAN EMILY SARID", "normalizedName": "rodriguez farfan emily sarid"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1001-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ FORERO SARA VALENTINA", "normalizedName": "rodriguez forero sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "1001-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUBA ACERO KEINER SAMUEL", "normalizedName": "suba acero keiner samuel"}, {"note": "Viene de 1003", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "1001-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TOCASUCHE ALFONSO JONATHAN STIVEN", "normalizedName": "tocasuche alfonso jonathan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "1001-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES GOMEZ JUAN DANIEL", "normalizedName": "torres gomez juan daniel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "1001-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES MAYORGA JUAN ESTEBAN", "normalizedName": "torres mayorga juan esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "1001-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALIENTE FERNANDEZ ANGIEE MARIANA", "normalizedName": "valiente fernandez angiee mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "1001-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA NAVARRETE DANNA VANESA", "normalizedName": "zamora navarrete danna vanesa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 36, "rowId": "1001-36", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA TORRES ALLISON VALERIA", "normalizedName": "zamora torres allison valeria"}, {"note": "Ret II-11", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 37, "rowId": "1001-37", "status": "retired", "retired": true, "studentId": null, "nationalId": null, "studentName": "PACHECO BARRIGA CAROL DAYANA", "normalizedName": "pacheco barriga carol dayana"}]	t	900100	2026-03-17 15:31:22.367601+01	2026-03-17 15:31:22.367601+01
23	1	\N	10	02	1002	10°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1002	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "10°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1002-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARRERA CASALLAS SARA SOFIA", "normalizedName": "barrera casallas sara sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1002-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES VILLAGRAN MIYER DANIEL", "normalizedName": "benavides villagran miyer daniel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1002-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUITRAGO PEÑA JHOJAN HERNANDO", "normalizedName": "buitrago pena jhojan hernando"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1002-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUSTOS NAVARRETE NICOL YULIETH", "normalizedName": "bustos navarrete nicol yulieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1002-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO OROSCO KAROLL MICHELL", "normalizedName": "castillo orosco karoll michell"}, {"note": "Viene de 1003", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1002-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CIPAGAUTA CATAÑO SARA MARIA", "normalizedName": "cipagauta catano sara maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1002-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CORREA JIMENEZ CRISTIAN NICOLAS", "normalizedName": "correa jimenez cristian nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1002-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DEAZA CRUZ OSCAR MAURICIO", "normalizedName": "deaza cruz oscar mauricio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1002-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DIAZ LANCHEROS ALISON MICHEL", "normalizedName": "diaz lancheros alison michel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1002-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL BENAVIDES GIOVANY ALEXANDER", "normalizedName": "gil benavides giovany alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1002-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL UMBARILA DIEGO GEOVANY", "normalizedName": "gil umbarila diego geovany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1002-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIRALDO MORA ANDRES FELIPE", "normalizedName": "giraldo mora andres felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1002-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ DIAZ ALIETH MARIANA", "normalizedName": "gomez diaz alieth mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1002-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ MEDINA JHOJAN STIVEN", "normalizedName": "gutierrez medina jhojan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1002-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JIMENEZ GORDILLO ANA MARIA", "normalizedName": "jimenez gordillo ana maria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1002-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA CUESTA MARIA SOFIA", "normalizedName": "lara cuesta maria sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1002-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA RAVELO DANNA CAMILA", "normalizedName": "lara ravelo danna camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1002-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARA VELANDIA DUBER SNEIDER", "normalizedName": "lara velandia duber sneider"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1002-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LIZARAZO ESPINOSA MARIA ALEJANDRA", "normalizedName": "lizarazo espinosa maria alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1002-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LIZARAZO JIMENEZ NICOLAS YAIR", "normalizedName": "lizarazo jimenez nicolas yair"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1002-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ TORRES JOHAN DAVID", "normalizedName": "lopez torres johan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1002-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON BULLA JOHAN SEBASTIAN", "normalizedName": "malagon bulla johan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1002-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON OSPINA SAMUEL ANDRES", "normalizedName": "malagon ospina samuel andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1002-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MARTINEZ DOZA KEVIN ALEXANDER", "normalizedName": "martinez doza kevin alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1002-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PARRA BARRERO SANTIAGO CAMILO", "normalizedName": "parra barrero santiago camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1002-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO GUTIERRFEZ DANA SOFIA", "normalizedName": "quintero gutierrfez dana sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1002-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ MURCIA BRENDA YORELI", "normalizedName": "ramirez murcia brenda yoreli"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1002-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMOS CABRERA LUIS DAVID", "normalizedName": "ramos cabrera luis david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1002-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIVAS CARDENAS SERGIO ANDRES", "normalizedName": "rivas cardenas sergio andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "1002-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ SARMIENTO LUISA FERNANDA", "normalizedName": "rodriguez sarmiento luisa fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "1002-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SOSA FORERO LIZETH JIMENA", "normalizedName": "sosa forero lizeth jimena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "1002-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES GOMEZ SHEYLA MARYURI", "normalizedName": "torres gomez sheyla maryuri"}]	t	900100	2026-03-17 15:31:22.370152+01	2026-03-17 15:31:22.370152+01
24	1	\N	10	03	1003	10°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1003	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "10°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1003-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ACOSTA PRIETO JUAN DAVID", "normalizedName": "acosta prieto juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1003-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BERNAL CASTAÑEDA DANIEL IGNACIO", "normalizedName": "bernal castaneda daniel ignacio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1003-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUITRAGO LIZARAZO MIGUEL ANGEL", "normalizedName": "buitrago lizarazo miguel angel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1003-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA TORRES ANGIE KATERINE", "normalizedName": "cabuya torres angie katerine"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1003-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARRILLO REINA JUAN CAMILO", "normalizedName": "carrillo reina juan camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1003-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAVEZ GIL EDWIN ARLEY", "normalizedName": "chavez gil edwin arley"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1003-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CIRCA CAMARGO NICOLAS GERONIMO", "normalizedName": "circa camargo nicolas geronimo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1003-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS HURTADO JELANY SOFIA", "normalizedName": "contreras hurtado jelany sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1003-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CORTÉS CASTILLO LEIDY YULIETH", "normalizedName": "cortes castillo leidy yulieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1003-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ MONTOYA YISED ZAMARA", "normalizedName": "cruz montoya yised zamara"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1003-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CRUZ RUEDA JULIANA SALOME", "normalizedName": "cruz rueda juliana salome"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1003-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESPINOSA PEREZ NICOLAS MATEO", "normalizedName": "espinosa perez nicolas mateo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1003-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESTUPIÑAN MOLINA ANGEL ESTEBAN", "normalizedName": "estupinan molina angel esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1003-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO MURCIA LAURA ALEXANDRA", "normalizedName": "forero murcia laura alexandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1003-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARCIA MEDINA CRISTHIAN CAMILO", "normalizedName": "garcia medina cristhian camilo"}, {"note": "N III-2", "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1003-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ QUINTERO JUAN PABLO", "normalizedName": "gomez quintero juan pablo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1003-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ RODRÍGUEZ PAULA SOFIA", "normalizedName": "lopez rodriguez paula sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1003-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON VARGAS JHON SAMUEL", "normalizedName": "malagon vargas jhon samuel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1003-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONDRAGON JUEZ KEVIN SANTIAGO", "normalizedName": "mondragon juez kevin santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1003-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS BARRIGA MAIKOL FABIAN", "normalizedName": "penagos barriga maikol fabian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1003-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINEDA PALACIOS STEFANY VALERIA", "normalizedName": "pineda palacios stefany valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1003-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON PRIMICIERO BRANDON ESTEBAN", "normalizedName": "pinzon primiciero brandon esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1003-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON SANCHEZ YEISON", "normalizedName": "pinzon sanchez yeison"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1003-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PRIMICIERO SOTO ZAIRA ISABELLA", "normalizedName": "primiciero soto zaira isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1003-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUEVEDO BARRERO MARIA ALEJANDRA", "normalizedName": "quevedo barrero maria alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1003-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ GIL LAURA NATALIA", "normalizedName": "rodriguez gil laura natalia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1003-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RONCANCIO RIAÑO BRENDA SOFIA", "normalizedName": "roncancio riano brenda sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1003-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TOLEDO MARIN NICOLAS JERONIMO", "normalizedName": "toledo marin nicolas jeronimo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1003-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA LAMPREA JOHAN SEBASTIAN", "normalizedName": "umbarila lamprea johan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "1003-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA MONTENEGRO EDWAR NICOLAS", "normalizedName": "umbarila montenegro edwar nicolas"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "1003-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UYAZAN PEÑALOZA HELEN CAMILA", "normalizedName": "uyazan penaloza helen camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "1003-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VASQUEZ SUA LINA MARCELA", "normalizedName": "vasquez sua lina marcela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "1003-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VILLARRAGA VASQUEZ VALENTINA", "normalizedName": "villarraga vasquez valentina"}]	t	900100	2026-03-17 15:31:22.37222+01	2026-03-17 15:31:22.37222+01
25	1	\N	10	04	1004	10°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1004	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "10°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1004-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AGUAS RUBIANO HEDRIAN FELIPE", "normalizedName": "aguas rubiano hedrian felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1004-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASALLAS VALBUENA NICOL DANIELA", "normalizedName": "casallas valbuena nicol daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1004-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTEBLANCO GIL SARA SOFIA", "normalizedName": "casteblanco gil sara sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1004-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO OROSCO ISABEL", "normalizedName": "castillo orosco isabel"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1004-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO LANCHEROS JUAN DAVID", "normalizedName": "castro lancheros juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1004-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO PASCAGAZA YEISSON ARBEY", "normalizedName": "castro pascagaza yeisson arbey"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1004-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUEVAS CAMELO LAURA JULIETH", "normalizedName": "cuevas camelo laura julieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1004-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FERNANDEZ ESTUPIÑAN JUAN ANDRES", "normalizedName": "fernandez estupinan juan andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1004-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ RAMIREZ KAREN TATIANA", "normalizedName": "gomez ramirez karen tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1004-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOYENECHE MANRIQUE JUAN DAVID", "normalizedName": "goyeneche manrique juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1004-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ MERCADO ALEJANDRO", "normalizedName": "gutierrez mercado alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1004-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ GUALDRON LEIDY MANUELA", "normalizedName": "lopez gualdron leidy manuela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1004-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ SALGADO MATIAS", "normalizedName": "lopez salgado matias"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1004-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MEDINA TOVAR NATALIA", "normalizedName": "medina tovar natalia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1004-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO GOMEZ SHAROL TATIANA", "normalizedName": "montenegro gomez sharol tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1004-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NAVARRETE RUBIO CHAROL BRIYITH", "normalizedName": "navarrete rubio charol briyith"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1004-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NOPE REYES KAROL NATALIA", "normalizedName": "nope reyes karol natalia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1004-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NOSSA SARMIENTO JUAN DAVID", "normalizedName": "nossa sarmiento juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1004-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PAEZ NIÑO CRISTOPHER RAFAEL", "normalizedName": "paez nino cristopher rafael"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1004-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PENAGOS DUQUE SARA SOFIA", "normalizedName": "penagos duque sara sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1004-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PULIDO IBAGUE HEIDY TATIANA", "normalizedName": "pulido ibague heidy tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1004-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUEVEDO RAMIREZ SHARIT TATIANA", "normalizedName": "quevedo ramirez sharit tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1004-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUICHE VARGAS DANNA GABRIELA", "normalizedName": "quiche vargas danna gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1004-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RESTREPO MAYA SOFIA", "normalizedName": "restrepo maya sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1004-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIVERA RUBIANO LINA VANESSA", "normalizedName": "rivera rubiano lina vanessa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1004-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ MALAGON PAOLA ANDREA", "normalizedName": "rodriguez malagon paola andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1004-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ PRIETO KAREN XIMENA", "normalizedName": "rodriguez prieto karen ximena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1004-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ RAQUIRA EILYN SOFIA", "normalizedName": "rodriguez raquira eilyn sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1004-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROZO GARCIA ANGGIE TATIANA", "normalizedName": "rozo garcia anggie tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "1004-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUBIANO MELO JAIRO JESUS", "normalizedName": "rubiano melo jairo jesus"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "1004-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALBUENA SUAREZ ANGIE DANIELA", "normalizedName": "valbuena suarez angie daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "1004-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VARGAS BARRETO EIDER MAURICIO", "normalizedName": "vargas barreto eider mauricio"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "1004-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SIERRA ESPINEL YON JAIRO Ret II-24", "normalizedName": "sierra espinel yon jairo ret ii 24"}]	t	900100	2026-03-17 15:31:22.374022+01	2026-03-17 15:31:22.374022+01
26	1	\N	11	01	1101	11°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1101	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "11°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1101-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ALVAREZ CIRCA MARIA CAMILA", "normalizedName": "alvarez circa maria camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1101-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BASTO PUENTES FRANKLIN ANDRES", "normalizedName": "basto puentes franklin andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1101-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA OLAVE DANNA SOFIA", "normalizedName": "cabuya olave danna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1101-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARDENAS CHICUAZUQUE SARA VALENTINA", "normalizedName": "cardenas chicuazuque sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1101-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAVARRO GORDILLO DAYRA ISABELLA", "normalizedName": "chavarro gordillo dayra isabella"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1101-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS FERNANDEZ ALISSON GABRIELA", "normalizedName": "contreras fernandez alisson gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1101-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON CRUZ SARA VALENTINA", "normalizedName": "garzon cruz sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1101-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GOMEZ DEISY MILENA", "normalizedName": "gil gomez deisy milena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1101-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ ESCOBAR JOHAN SANTIAGO", "normalizedName": "gomez escobar johan santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1101-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ CALDAS ANGIE LORENA", "normalizedName": "gutierrez caldas angie lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1101-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HUERFANO PIRA SANTIAGO", "normalizedName": "huerfano pira santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1101-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "JIMENEZ LOPEZ EDWIN HERNAN", "normalizedName": "jimenez lopez edwin hernan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1101-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LARGO MEDINA SHARYTH VALENTINA", "normalizedName": "largo medina sharyth valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1101-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LIZARAZO CASALLAS JUAN DAVID", "normalizedName": "lizarazo casallas juan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1101-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LOPEZ BALLEN JULIAN SANTIAGO", "normalizedName": "lopez ballen julian santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1101-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LUNA RODRIGUEZ SARA VALENTINA", "normalizedName": "luna rodriguez sara valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1101-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO MARIN CRISTHIAN ALBERTO", "normalizedName": "montenegro marin cristhian alberto"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1101-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MONTENEGRO PASCAGAZA KAREN ESTEFANIA", "normalizedName": "montenegro pascagaza karen estefania"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1101-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA MORA DUVER ESTEBAN", "normalizedName": "mora mora duver esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1101-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO CABALLERO BRAYAN ALEXANDER", "normalizedName": "moreno caballero brayan alexander"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1101-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NOVA TOBAR CRISTIAN ANDRES", "normalizedName": "nova tobar cristian andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1101-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PACHOTE MONTAÑO ANGIE VALENTINA", "normalizedName": "pachote montano angie valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1101-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PIRA QUIROGA JUAN CAMILO", "normalizedName": "pira quiroga juan camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1101-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PUENTES RODRIGUEZ SIMON DAVID", "normalizedName": "puentes rodriguez simon david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1101-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO BENAVIDES ANA YURANY", "normalizedName": "quintero benavides ana yurany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1101-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIAÑO QUINTERO NICOLL DANIELA", "normalizedName": "riano quintero nicoll daniela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1101-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RIOS GARZON JUAN JOSE", "normalizedName": "rios garzon juan jose"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1101-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTA FE CONTRERAS NICOLLE VANESSA", "normalizedName": "santa fe contreras nicolle vanessa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1101-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "URIBE ORJUELA TANIA MICHELLE", "normalizedName": "uribe orjuela tania michelle"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "1101-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VERDUGO VARGAS MANUEL SANTIAGO", "normalizedName": "verdugo vargas manuel santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "1101-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA CONTRERAS JUAN DAVID Des II)", "normalizedName": "mora contreras juan david des ii"}]	t	900100	2026-03-17 15:31:22.375983+01	2026-03-17 15:31:22.375983+01
27	1	\N	11	02	1102	11°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1102	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "11°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1102-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ABRIL CASTAÑEDA DUVAN FELIPE", "normalizedName": "abril castaneda duvan felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1102-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AGUILAR BUSTOS SALMA VALERIA", "normalizedName": "aguilar bustos salma valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1102-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO MORENO DANIA LISETH", "normalizedName": "arevalo moreno dania liseth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1102-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BELTRAN LINARES CRISTIAN DAVID", "normalizedName": "beltran linares cristian david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1102-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BENAVIDES ABRIL ANDRES SANTIAGO", "normalizedName": "benavides abril andres santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1102-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUITRAGO GIL JOHAN DAVID", "normalizedName": "buitrago gil johan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1102-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CABUYA CHICAGUY LAURA YIZETH", "normalizedName": "cabuya chicaguy laura yizeth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1102-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CARDENAS NAVARRETE ANDREA CATALINA", "normalizedName": "cardenas navarrete andrea catalina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1102-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTRO BARRANTES SAMUEL ESTEBAN", "normalizedName": "castro barrantes samuel esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1102-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAVES CASTAÑEDA JULIAN YESID", "normalizedName": "chaves castaneda julian yesid"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1102-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "DIAZ REY ALISON GABRIELA", "normalizedName": "diaz rey alison gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1102-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ RUBIANO LUNA ABIGAIL", "normalizedName": "gomez rubiano luna abigail"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1102-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUALTEROS CASTEBLANCO EDWAR FELIPE", "normalizedName": "gualteros casteblanco edwar felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1102-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUEVARA BERNAL DAIRON ESTEBAN", "normalizedName": "guevara bernal dairon esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1102-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GUTIERREZ RAMIREZ JOSE ALEJANDRO", "normalizedName": "gutierrez ramirez jose alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1102-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LAVADO SARMIENTO MIGUEL ADRIAN", "normalizedName": "lavado sarmiento miguel adrian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1102-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "LIZARAZO GIL EDWIN ORLANDO", "normalizedName": "lizarazo gil edwin orlando"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1102-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA GONZALEZ JULIAN GUILLERMO", "normalizedName": "mora gonzalez julian guillermo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1102-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PARRA PEREZ JUDITH ALEJANDRA", "normalizedName": "parra perez judith alejandra"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1102-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEREZ RODRIGUEZ DAVID SANTIAGO", "normalizedName": "perez rodriguez david santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1102-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINEDA CABUYA LAURA XIMENA", "normalizedName": "pineda cabuya laura ximena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1102-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PULIDO GUACANEME JHONATAN DAVID", "normalizedName": "pulido guacaneme jhonatan david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1102-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO UMBARILA BRAYAN STIVEN", "normalizedName": "quintero umbarila brayan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1102-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ LOTTA ANGEL SIMON", "normalizedName": "ramirez lotta angel simon"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1102-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RODRIGUEZ PENAGOS PAULA GABRIELA", "normalizedName": "rodriguez penagos paula gabriela"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1102-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUIZ ARENAS TANIA CAMILA", "normalizedName": "ruiz arenas tania camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1102-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANCHEZ NAVARRETE MARIA PAULA", "normalizedName": "sanchez navarrete maria paula"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1102-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA CABRERA KAROL DAYANA", "normalizedName": "zamora cabrera karol dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1102-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ZAMORA RIAÑO JUAN MANUEL", "normalizedName": "zamora riano juan manuel"}]	t	900100	2026-03-17 15:31:22.378977+01	2026-03-17 15:31:22.378977+01
28	1	\N	11	03	1103	11°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1103	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "11°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1103-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AGUILAR MOLINA DIEGO ALEJANDRO", "normalizedName": "aguilar molina diego alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1103-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BUITRAGO LIZARAZO SAMUEL EDUARDO", "normalizedName": "buitrago lizarazo samuel eduardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1103-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTAÑEDA SARMIENTO LUIS FELIPE", "normalizedName": "castaneda sarmiento luis felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1103-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO SÁNCHEZ MARÍA FERNANDA", "normalizedName": "castillo sanchez maria fernanda"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1103-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAVARRIO OTALORA MAURE LISETH", "normalizedName": "chavarrio otalora maure liseth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1103-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHIGUACHI SUAREZ LAURA MARIANA", "normalizedName": "chiguachi suarez laura mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1103-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS PEREZ VALERIA", "normalizedName": "contreras perez valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1103-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUESTA MAYORGA SERGIO ANDRÉS", "normalizedName": "cuesta mayorga sergio andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1103-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CUEVAS RODRÍGUEZ PAULA SORANYI", "normalizedName": "cuevas rodriguez paula soranyi"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1103-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ESPINOSA PEREZ KENNY JOHAN", "normalizedName": "espinosa perez kenny johan"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1103-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO BARÓN JULIAN CAMILO", "normalizedName": "forero baron julian camilo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1103-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO MURCIA ANGIE SOFIA", "normalizedName": "forero murcia angie sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1103-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL BALLEN LUIS SANTIAGO", "normalizedName": "gil ballen luis santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1103-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "HERNANDEZ GALINDO JOHAN STIVEN", "normalizedName": "hernandez galindo johan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1103-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MANTILLA OLAVE SEBASTIAN DAVID", "normalizedName": "mantilla olave sebastian david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1103-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORENO QUIROGA PAULA JOHANA", "normalizedName": "moreno quiroga paula johana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1103-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "OROZCO PEDROZO SHARITH", "normalizedName": "orozco pedrozo sharith"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1103-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PULGARIN ESPITIA PAULA SOFIA", "normalizedName": "pulgarin espitia paula sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1103-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "QUINTERO SUAREZ JUAN FELIPE", "normalizedName": "quintero suarez juan felipe"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1103-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMIREZ PINEDA JOHAN STEVEN", "normalizedName": "ramirez pineda johan steven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1103-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMOS LARA YAKELINE", "normalizedName": "ramos lara yakeline"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1103-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAQUIRA FARFÁN LEIDY CAROLINA", "normalizedName": "raquira farfan leidy carolina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1103-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAQUIRA FARFAN LILIANA ANDREA", "normalizedName": "raquira farfan liliana andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1103-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROBAYO GIRALDO JOSÉ MATIAS", "normalizedName": "robayo giraldo jose matias"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1103-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROBAYO SANTAMARIA NOHELIA", "normalizedName": "robayo santamaria nohelia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1103-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROJAS ORJUELA HEIDY YULIETH", "normalizedName": "rojas orjuela heidy yulieth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1103-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUIZ JIMENEZ JOSÉ ALEJANDRO", "normalizedName": "ruiz jimenez jose alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1103-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SANTAMARIA CRUZ EDWIN ALEJANDRO", "normalizedName": "santamaria cruz edwin alejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1103-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES GUTIERREZ SERGIO ESTEBAN", "normalizedName": "torres gutierrez sergio esteban"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "1103-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES RODRÍGUEZ LAURA CAMILA", "normalizedName": "torres rodriguez laura camila"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "1103-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TORRES YEPES YOVAN STIVEN", "normalizedName": "torres yepes yovan stiven"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "1103-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "TUMAY GOMEZ NORMA CHARITH", "normalizedName": "tumay gomez norma charith"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 33, "rowId": "1103-33", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA LARA MARIA ESTEFANY", "normalizedName": "umbarila lara maria estefany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 34, "rowId": "1103-34", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VENEGAS ABRIL ANGEL MATHIAS", "normalizedName": "venegas abril angel mathias"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 35, "rowId": "1103-35", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VILLAMIZAR LISBETH TATIANA", "normalizedName": "villamizar lisbeth tatiana"}]	t	900100	2026-03-17 15:31:22.380663+01	2026-03-17 15:31:22.380663+01
29	1	\N	11	04	1104	11°	Planillas de Notas IEDRC 2026 Marzo 12 Secundaria.xlsx	iedrc-secondary-v1	Planilla 1104	{"institution": "IED Rufino Cuervo", "periodLabel": "", "sourceSheet": "11°", "subjectName": "", "teacherName": "", "classGroupId": null, "templateLabel": "Registro de valoraciones evaluativas"}	[{"key": "act_1", "type": "text", "group": "Actitudinal", "label": "1.0"}, {"key": "act_2", "type": "text", "group": "Actitudinal", "label": "2.0"}, {"key": "act_3", "type": "text", "group": "Actitudinal", "label": "3.0"}, {"key": "act_4", "type": "text", "group": "Actitudinal", "label": "4.0"}, {"key": "proc_1", "type": "text", "group": "Procedimental", "label": "1.0"}, {"key": "proc_2", "type": "text", "group": "Procedimental", "label": "2.0"}, {"key": "proc_3", "type": "text", "group": "Procedimental", "label": "3.0"}, {"key": "proc_4", "type": "text", "group": "Procedimental", "label": "4.0"}, {"key": "cog_1", "type": "text", "group": "Cognitivo", "label": "1.0"}, {"key": "cog_2", "type": "text", "group": "Cognitivo", "label": "2.0"}, {"key": "cog_3", "type": "text", "group": "Cognitivo", "label": "3.0"}, {"key": "cog_4", "type": "text", "group": "Cognitivo", "label": "4.0"}, {"key": "final", "type": "text", "group": "Final", "label": "Final"}, {"key": "inasistencia", "type": "text", "group": "Inasistencia", "label": "Inasistencia"}]	[{"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 1, "rowId": "1104-1", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO MORA YESICA TATIANA", "normalizedName": "arevalo mora yesica tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 2, "rowId": "1104-2", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "AREVALO RIAÑO ANGY MARIANA", "normalizedName": "arevalo riano angy mariana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 3, "rowId": "1104-3", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "BARBOSA RODRIGUEZ MELHANY", "normalizedName": "barbosa rodriguez melhany"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 4, "rowId": "1104-4", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CASTILLO RAMIREZ MABEL SOFIA", "normalizedName": "castillo ramirez mabel sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 5, "rowId": "1104-5", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CHAUTA MUÑOZ KYLLIAM YAIR", "normalizedName": "chauta munoz kylliam yair"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 6, "rowId": "1104-6", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "CONTRERAS GUEVARA LOREEN JULIANA", "normalizedName": "contreras guevara loreen juliana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 7, "rowId": "1104-7", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FLOREZ ESCALENTE JESUS YHONAIKER", "normalizedName": "florez escalente jesus yhonaiker"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 8, "rowId": "1104-8", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "FORERO PARRA KAREN DAYANA", "normalizedName": "forero parra karen dayana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 9, "rowId": "1104-9", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GARZON CASTRO ANGIE YAMILE", "normalizedName": "garzon castro angie yamile"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 10, "rowId": "1104-10", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GIL INGRID CAROLINA", "normalizedName": "gil gil ingrid carolina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 11, "rowId": "1104-11", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GIL GOMEZ KAREN ANDREA", "normalizedName": "gil gomez karen andrea"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 12, "rowId": "1104-12", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "GOMEZ VELASQUEZ JUAN SEBASTIAN", "normalizedName": "gomez velasquez juan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 13, "rowId": "1104-13", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MALAGON SUAREZ KAREN SOFIA", "normalizedName": "malagon suarez karen sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 14, "rowId": "1104-14", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MAYORGA GARZON DIEGO ANDRES", "normalizedName": "mayorga garzon diego andres"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 15, "rowId": "1104-15", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MORA GOMEZ JULIAN DAVID", "normalizedName": "mora gomez julian david"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 16, "rowId": "1104-16", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MURCIA AREVALO ANYULY JEANETH", "normalizedName": "murcia arevalo anyuly jeaneth"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 17, "rowId": "1104-17", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "MURCIA AREVALO IBETH JENARY", "normalizedName": "murcia arevalo ibeth jenary"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 18, "rowId": "1104-18", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "NAVARRETE SUAREZ YOHAN SEBASTIAN", "normalizedName": "navarrete suarez yohan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 19, "rowId": "1104-19", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEDRAZA CABUYA DEIVI AEJANDRO", "normalizedName": "pedraza cabuya deivi aejandro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 20, "rowId": "1104-20", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PEDREROS CASTAÑEDA YOHAN SEBASTIAN", "normalizedName": "pedreros castaneda yohan sebastian"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 21, "rowId": "1104-21", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON CASTRO ANGIE LORENA", "normalizedName": "pinzon castro angie lorena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 22, "rowId": "1104-22", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "PINZON VALENZUELA LAURA VALERIA", "normalizedName": "pinzon valenzuela laura valeria"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 23, "rowId": "1104-23", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RAMOS LARA ANA MILENA", "normalizedName": "ramos lara ana milena"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 24, "rowId": "1104-24", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "ROBAYO BERNAL JENNIFER VALENTINA", "normalizedName": "robayo bernal jennifer valentina"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 25, "rowId": "1104-25", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "RUIZ ALARCON DANNA SOFIA", "normalizedName": "ruiz alarcon danna sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 26, "rowId": "1104-26", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SARMIENTO DIAZ RAFAEL RICARDO", "normalizedName": "sarmiento diaz rafael ricardo"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 27, "rowId": "1104-27", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SILVA SUAREZ LAURA SOFIA", "normalizedName": "silva suarez laura sofia"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 28, "rowId": "1104-28", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUAREZ HENAO KEVIN ALBEIRO", "normalizedName": "suarez henao kevin albeiro"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 29, "rowId": "1104-29", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "SUAREZ SANCHEZ NICOLLE VANNESA", "normalizedName": "suarez sanchez nicolle vannesa"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 30, "rowId": "1104-30", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA DOZA DAVID SANTIAGO", "normalizedName": "umbarila doza david santiago"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 31, "rowId": "1104-31", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "UMBARILA LAMPREA BRENDA TATIANA", "normalizedName": "umbarila lamprea brenda tatiana"}, {"note": null, "cells": {"act_1": "", "act_2": "", "act_3": "", "act_4": "", "cog_1": "", "cog_2": "", "cog_3": "", "cog_4": "", "final": "", "proc_1": "", "proc_2": "", "proc_3": "", "proc_4": "", "inasistencia": ""}, "order": 32, "rowId": "1104-32", "status": "pending_id", "retired": false, "studentId": null, "nationalId": null, "studentName": "VALDERRAMA PENAGOS JUAN FELIPE", "normalizedName": "valderrama penagos juan felipe"}]	t	900100	2026-03-17 15:31:22.382476+01	2026-03-17 15:31:22.382476+01
\.


--
-- Data for Name: school_years; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.school_years (school_year_id, name, year_start, year_end, is_active, created_at) FROM stdin;
1	2026	2026-01-01	2026-12-31	t	2026-02-18 19:13:52.452563+01
\.


--
-- Data for Name: students; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.students (student_id, national_id, first_name, last_name, dob, address, guardian_name, guardian_relationship, guardian_phone, is_active, created_at, updated_at, deleted_at, gender) FROM stdin;
1	000001	aaa	aaa	2000-02-25	aaa	aaa	aaa	1234567	t	2026-02-28 18:13:34.655704+01	2026-02-28 18:13:34.655704+01	\N	No Binario
2	000002	aab	aab	2000-08-24	aab	aab	aab	123456789	t	2026-03-04 16:49:19.163047+01	2026-03-04 16:49:19.163047+01	\N	No Binario
3	000005	Rash	Butt	2003-01-16	abs 67	Jorge	Padre	12345789	t	2026-03-09 18:44:46.518304+01	2026-03-09 18:44:46.518304+01	\N	No Binario
4	0000079	Juan	Nuaj	2006-06-21	adjks	Mama Mia	Madre	21445346	t	2026-03-09 19:47:00.891219+01	2026-03-09 19:47:00.891219+01	\N	No Binario
5	950001	Juan	GóMez	2015-01-01	Dirección 950001	Madre de Juan	Madre	3000950001	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
6	950051	Juan	GóMez	2014-01-01	Dirección 950051	Madre de Juan	Madre	3000950051	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
7	950101	Juan	GóMez	2013-01-01	Dirección 950101	Madre de Juan	Madre	3000950101	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
8	950151	Juan	GóMez	2012-01-01	Dirección 950151	Madre de Juan	Madre	3000950151	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
9	950201	Juan	GóMez	2011-01-01	Dirección 950201	Madre de Juan	Madre	3000950201	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
10	950251	Juan	GóMez	2010-01-01	Dirección 950251	Madre de Juan	Madre	3000950251	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
11	950301	Juan	GóMez	2009-01-01	Dirección 950301	Madre de Juan	Madre	3000950301	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
12	950002	MaríA	RodríGuez	2015-02-02	Dirección 950002	Madre de MaríA	Madre	3000950002	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
13	950052	MaríA	RodríGuez	2014-02-02	Dirección 950052	Madre de MaríA	Madre	3000950052	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
14	950102	MaríA	RodríGuez	2013-02-02	Dirección 950102	Madre de MaríA	Madre	3000950102	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
15	950152	MaríA	RodríGuez	2012-02-02	Dirección 950152	Madre de MaríA	Madre	3000950152	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
16	950202	MaríA	RodríGuez	2011-02-02	Dirección 950202	Madre de MaríA	Madre	3000950202	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
17	950252	MaríA	RodríGuez	2010-02-02	Dirección 950252	Madre de MaríA	Madre	3000950252	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
18	950302	MaríA	RodríGuez	2009-02-02	Dirección 950302	Madre de MaríA	Madre	3000950302	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
19	950003	Laura	MartíNez	2015-03-03	Dirección 950003	Madre de Laura	Madre	3000950003	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
20	950053	Laura	MartíNez	2014-03-03	Dirección 950053	Madre de Laura	Madre	3000950053	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
21	950103	Laura	MartíNez	2013-03-03	Dirección 950103	Madre de Laura	Madre	3000950103	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
22	950153	Laura	MartíNez	2012-03-03	Dirección 950153	Madre de Laura	Madre	3000950153	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
23	950203	Laura	MartíNez	2011-03-03	Dirección 950203	Madre de Laura	Madre	3000950203	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
24	950253	Laura	MartíNez	2010-03-03	Dirección 950253	Madre de Laura	Madre	3000950253	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
25	950303	Laura	MartíNez	2009-03-03	Dirección 950303	Madre de Laura	Madre	3000950303	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
26	950004	Carlos	LóPez	2015-04-04	Dirección 950004	Madre de Carlos	Madre	3000950004	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
27	950054	Carlos	LóPez	2014-04-04	Dirección 950054	Madre de Carlos	Madre	3000950054	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
28	950104	Carlos	LóPez	2013-04-04	Dirección 950104	Madre de Carlos	Madre	3000950104	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
29	950154	Carlos	LóPez	2012-04-04	Dirección 950154	Madre de Carlos	Madre	3000950154	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
30	950204	Carlos	LóPez	2011-04-04	Dirección 950204	Madre de Carlos	Madre	3000950204	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
31	950254	Carlos	LóPez	2010-04-04	Dirección 950254	Madre de Carlos	Madre	3000950254	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
32	950304	Carlos	LóPez	2009-04-04	Dirección 950304	Madre de Carlos	Madre	3000950304	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
33	950005	AndréS	HernáNdez	2015-05-05	Dirección 950005	Madre de AndréS	Madre	3000950005	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
34	950055	AndréS	HernáNdez	2014-05-05	Dirección 950055	Madre de AndréS	Madre	3000950055	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
35	950105	AndréS	HernáNdez	2013-05-05	Dirección 950105	Madre de AndréS	Madre	3000950105	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
36	950155	AndréS	HernáNdez	2012-05-05	Dirección 950155	Madre de AndréS	Madre	3000950155	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
37	950205	AndréS	HernáNdez	2011-05-05	Dirección 950205	Madre de AndréS	Madre	3000950205	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
38	950255	AndréS	HernáNdez	2010-05-05	Dirección 950255	Madre de AndréS	Madre	3000950255	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
39	950305	AndréS	HernáNdez	2009-05-05	Dirección 950305	Madre de AndréS	Madre	3000950305	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
40	950006	Camila	GarcíA	2015-06-06	Dirección 950006	Madre de Camila	Madre	3000950006	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
41	950056	Camila	GarcíA	2014-06-06	Dirección 950056	Madre de Camila	Madre	3000950056	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
42	950106	Camila	GarcíA	2013-06-06	Dirección 950106	Madre de Camila	Madre	3000950106	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
43	950156	Camila	GarcíA	2012-06-06	Dirección 950156	Madre de Camila	Madre	3000950156	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
44	950206	Camila	GarcíA	2011-06-06	Dirección 950206	Madre de Camila	Madre	3000950206	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
45	950256	Camila	GarcíA	2010-06-06	Dirección 950256	Madre de Camila	Madre	3000950256	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
46	950306	Camila	GarcíA	2009-06-06	Dirección 950306	Madre de Camila	Madre	3000950306	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
47	950007	SofíA	PéRez	2015-07-07	Dirección 950007	Madre de SofíA	Madre	3000950007	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
48	950057	SofíA	PéRez	2014-07-07	Dirección 950057	Madre de SofíA	Madre	3000950057	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
49	950107	SofíA	PéRez	2013-07-07	Dirección 950107	Madre de SofíA	Madre	3000950107	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
50	950157	SofíA	PéRez	2012-07-07	Dirección 950157	Madre de SofíA	Madre	3000950157	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
51	950207	SofíA	PéRez	2011-07-07	Dirección 950207	Madre de SofíA	Madre	3000950207	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
52	950257	SofíA	PéRez	2010-07-07	Dirección 950257	Madre de SofíA	Madre	3000950257	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
53	950307	SofíA	PéRez	2009-07-07	Dirección 950307	Madre de SofíA	Madre	3000950307	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
54	950008	Mateo	SáNchez	2015-08-08	Dirección 950008	Madre de Mateo	Madre	3000950008	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
55	950058	Mateo	SáNchez	2014-08-08	Dirección 950058	Madre de Mateo	Madre	3000950058	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
56	950108	Mateo	SáNchez	2013-08-08	Dirección 950108	Madre de Mateo	Madre	3000950108	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
57	950158	Mateo	SáNchez	2012-08-08	Dirección 950158	Madre de Mateo	Madre	3000950158	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
58	950208	Mateo	SáNchez	2011-08-08	Dirección 950208	Madre de Mateo	Madre	3000950208	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
59	950258	Mateo	SáNchez	2010-08-08	Dirección 950258	Madre de Mateo	Madre	3000950258	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
60	950308	Mateo	SáNchez	2009-08-08	Dirección 950308	Madre de Mateo	Madre	3000950308	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
61	950009	Valentina	RamíRez	2015-09-09	Dirección 950009	Madre de Valentina	Madre	3000950009	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
62	950059	Valentina	RamíRez	2014-09-09	Dirección 950059	Madre de Valentina	Madre	3000950059	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
63	950109	Valentina	RamíRez	2013-09-09	Dirección 950109	Madre de Valentina	Madre	3000950109	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
64	950159	Valentina	RamíRez	2012-09-09	Dirección 950159	Madre de Valentina	Madre	3000950159	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
65	950209	Valentina	RamíRez	2011-09-09	Dirección 950209	Madre de Valentina	Madre	3000950209	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
66	950259	Valentina	RamíRez	2010-09-09	Dirección 950259	Madre de Valentina	Madre	3000950259	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
67	950309	Valentina	RamíRez	2009-09-09	Dirección 950309	Madre de Valentina	Madre	3000950309	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
68	950010	Daniel	Torres	2015-10-10	Dirección 950010	Madre de Daniel	Madre	3000950010	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
69	950060	Daniel	Torres	2014-10-10	Dirección 950060	Madre de Daniel	Madre	3000950060	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
70	950110	Daniel	Torres	2013-10-10	Dirección 950110	Madre de Daniel	Madre	3000950110	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
71	950160	Daniel	Torres	2012-10-10	Dirección 950160	Madre de Daniel	Madre	3000950160	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
72	950210	Daniel	Torres	2011-10-10	Dirección 950210	Madre de Daniel	Madre	3000950210	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
73	950260	Daniel	Torres	2010-10-10	Dirección 950260	Madre de Daniel	Madre	3000950260	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
74	950310	Daniel	Torres	2009-10-10	Dirección 950310	Madre de Daniel	Madre	3000950310	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
75	950011	Santiago	DíAz	2015-11-11	Dirección 950011	Madre de Santiago	Madre	3000950011	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
76	950061	Santiago	DíAz	2014-11-11	Dirección 950061	Madre de Santiago	Madre	3000950061	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
77	950111	Santiago	DíAz	2013-11-11	Dirección 950111	Madre de Santiago	Madre	3000950111	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
78	950161	Santiago	DíAz	2012-11-11	Dirección 950161	Madre de Santiago	Madre	3000950161	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
79	950211	Santiago	DíAz	2011-11-11	Dirección 950211	Madre de Santiago	Madre	3000950211	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
80	950261	Santiago	DíAz	2010-11-11	Dirección 950261	Madre de Santiago	Madre	3000950261	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
81	950311	Santiago	DíAz	2009-11-11	Dirección 950311	Madre de Santiago	Madre	3000950311	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
82	950012	Isabella	Vargas	2015-12-12	Dirección 950012	Madre de Isabella	Madre	3000950012	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
83	950062	Isabella	Vargas	2014-12-12	Dirección 950062	Madre de Isabella	Madre	3000950062	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
84	950112	Isabella	Vargas	2013-12-12	Dirección 950112	Madre de Isabella	Madre	3000950112	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
85	950162	Isabella	Vargas	2012-12-12	Dirección 950162	Madre de Isabella	Madre	3000950162	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
86	950212	Isabella	Vargas	2011-12-12	Dirección 950212	Madre de Isabella	Madre	3000950212	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
87	950262	Isabella	Vargas	2010-12-12	Dirección 950262	Madre de Isabella	Madre	3000950262	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
88	950312	Isabella	Vargas	2009-12-12	Dirección 950312	Madre de Isabella	Madre	3000950312	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
89	950013	Samuel	Castro	2015-01-13	Dirección 950013	Madre de Samuel	Madre	3000950013	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
90	950063	Samuel	Castro	2014-01-13	Dirección 950063	Madre de Samuel	Madre	3000950063	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
91	950113	Samuel	Castro	2013-01-13	Dirección 950113	Madre de Samuel	Madre	3000950113	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
92	950163	Samuel	Castro	2012-01-13	Dirección 950163	Madre de Samuel	Madre	3000950163	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
93	950213	Samuel	Castro	2011-01-13	Dirección 950213	Madre de Samuel	Madre	3000950213	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
94	950263	Samuel	Castro	2010-01-13	Dirección 950263	Madre de Samuel	Madre	3000950263	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
95	950313	Samuel	Castro	2009-01-13	Dirección 950313	Madre de Samuel	Madre	3000950313	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
96	950014	Juliana	Ruiz	2015-02-14	Dirección 950014	Madre de Juliana	Madre	3000950014	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
97	950064	Juliana	Ruiz	2014-02-14	Dirección 950064	Madre de Juliana	Madre	3000950064	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
98	950114	Juliana	Ruiz	2013-02-14	Dirección 950114	Madre de Juliana	Madre	3000950114	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
99	950164	Juliana	Ruiz	2012-02-14	Dirección 950164	Madre de Juliana	Madre	3000950164	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
100	950214	Juliana	Ruiz	2011-02-14	Dirección 950214	Madre de Juliana	Madre	3000950214	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
101	950264	Juliana	Ruiz	2010-02-14	Dirección 950264	Madre de Juliana	Madre	3000950264	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
102	950314	Juliana	Ruiz	2009-02-14	Dirección 950314	Madre de Juliana	Madre	3000950314	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
103	950015	NicoláS	Moreno	2015-03-15	Dirección 950015	Madre de NicoláS	Madre	3000950015	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
104	950065	NicoláS	Moreno	2014-03-15	Dirección 950065	Madre de NicoláS	Madre	3000950065	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
105	950115	NicoláS	Moreno	2013-03-15	Dirección 950115	Madre de NicoláS	Madre	3000950115	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
106	950165	NicoláS	Moreno	2012-03-15	Dirección 950165	Madre de NicoláS	Madre	3000950165	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
107	950215	NicoláS	Moreno	2011-03-15	Dirección 950215	Madre de NicoláS	Madre	3000950215	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
108	950265	NicoláS	Moreno	2010-03-15	Dirección 950265	Madre de NicoláS	Madre	3000950265	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
109	950315	NicoláS	Moreno	2009-03-15	Dirección 950315	Madre de NicoláS	Madre	3000950315	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
110	950016	Andrea	ÁLvarez	2015-04-16	Dirección 950016	Madre de Andrea	Madre	3000950016	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
111	950066	Andrea	ÁLvarez	2014-04-16	Dirección 950066	Madre de Andrea	Madre	3000950066	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
112	950116	Andrea	ÁLvarez	2013-04-16	Dirección 950116	Madre de Andrea	Madre	3000950116	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
113	950166	Andrea	ÁLvarez	2012-04-16	Dirección 950166	Madre de Andrea	Madre	3000950166	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
114	950216	Andrea	ÁLvarez	2011-04-16	Dirección 950216	Madre de Andrea	Madre	3000950216	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
115	950266	Andrea	ÁLvarez	2010-04-16	Dirección 950266	Madre de Andrea	Madre	3000950266	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
116	950316	Andrea	ÁLvarez	2009-04-16	Dirección 950316	Madre de Andrea	Madre	3000950316	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
117	950017	David	Rojas	2015-05-17	Dirección 950017	Madre de David	Madre	3000950017	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
118	950067	David	Rojas	2014-05-17	Dirección 950067	Madre de David	Madre	3000950067	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
119	950117	David	Rojas	2013-05-17	Dirección 950117	Madre de David	Madre	3000950117	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
120	950167	David	Rojas	2012-05-17	Dirección 950167	Madre de David	Madre	3000950167	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
121	950217	David	Rojas	2011-05-17	Dirección 950217	Madre de David	Madre	3000950217	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
122	950267	David	Rojas	2010-05-17	Dirección 950267	Madre de David	Madre	3000950267	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
123	950317	David	Rojas	2009-05-17	Dirección 950317	Madre de David	Madre	3000950317	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
124	950018	Paula	MuñOz	2015-06-18	Dirección 950018	Madre de Paula	Madre	3000950018	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
125	950068	Paula	MuñOz	2014-06-18	Dirección 950068	Madre de Paula	Madre	3000950068	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
126	950118	Paula	MuñOz	2013-06-18	Dirección 950118	Madre de Paula	Madre	3000950118	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
127	950168	Paula	MuñOz	2012-06-18	Dirección 950168	Madre de Paula	Madre	3000950168	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
128	950218	Paula	MuñOz	2011-06-18	Dirección 950218	Madre de Paula	Madre	3000950218	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
129	950268	Paula	MuñOz	2010-06-18	Dirección 950268	Madre de Paula	Madre	3000950268	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
130	950318	Paula	MuñOz	2009-06-18	Dirección 950318	Madre de Paula	Madre	3000950318	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
131	950019	Miguel	SuáRez	2015-07-19	Dirección 950019	Madre de Miguel	Madre	3000950019	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
132	950069	Miguel	SuáRez	2014-07-19	Dirección 950069	Madre de Miguel	Madre	3000950069	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
133	950119	Miguel	SuáRez	2013-07-19	Dirección 950119	Madre de Miguel	Madre	3000950119	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
134	950169	Miguel	SuáRez	2012-07-19	Dirección 950169	Madre de Miguel	Madre	3000950169	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
135	950219	Miguel	SuáRez	2011-07-19	Dirección 950219	Madre de Miguel	Madre	3000950219	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
136	950269	Miguel	SuáRez	2010-07-19	Dirección 950269	Madre de Miguel	Madre	3000950269	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
137	950319	Miguel	SuáRez	2009-07-19	Dirección 950319	Madre de Miguel	Madre	3000950319	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
138	950020	Gabriela	Cruz	2015-08-20	Dirección 950020	Madre de Gabriela	Madre	3000950020	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
139	950070	Gabriela	Cruz	2014-08-20	Dirección 950070	Madre de Gabriela	Madre	3000950070	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
140	950120	Gabriela	Cruz	2013-08-20	Dirección 950120	Madre de Gabriela	Madre	3000950120	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
141	950170	Gabriela	Cruz	2012-08-20	Dirección 950170	Madre de Gabriela	Madre	3000950170	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
142	950220	Gabriela	Cruz	2011-08-20	Dirección 950220	Madre de Gabriela	Madre	3000950220	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
143	950270	Gabriela	Cruz	2010-08-20	Dirección 950270	Madre de Gabriela	Madre	3000950270	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
144	950320	Gabriela	Cruz	2009-08-20	Dirección 950320	Madre de Gabriela	Madre	3000950320	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
145	950021	Juan	GóMez	2015-09-21	Dirección 950021	Madre de Juan	Madre	3000950021	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
146	950071	Juan	GóMez	2014-09-21	Dirección 950071	Madre de Juan	Madre	3000950071	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
147	950121	Juan	GóMez	2013-09-21	Dirección 950121	Madre de Juan	Madre	3000950121	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
148	950171	Juan	GóMez	2012-09-21	Dirección 950171	Madre de Juan	Madre	3000950171	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
149	950221	Juan	GóMez	2011-09-21	Dirección 950221	Madre de Juan	Madre	3000950221	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
150	950271	Juan	GóMez	2010-09-21	Dirección 950271	Madre de Juan	Madre	3000950271	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
151	950321	Juan	GóMez	2009-09-21	Dirección 950321	Madre de Juan	Madre	3000950321	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
152	950022	MaríA	RodríGuez	2015-10-22	Dirección 950022	Madre de MaríA	Madre	3000950022	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
153	950072	MaríA	RodríGuez	2014-10-22	Dirección 950072	Madre de MaríA	Madre	3000950072	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
154	950122	MaríA	RodríGuez	2013-10-22	Dirección 950122	Madre de MaríA	Madre	3000950122	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
155	950172	MaríA	RodríGuez	2012-10-22	Dirección 950172	Madre de MaríA	Madre	3000950172	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
156	950222	MaríA	RodríGuez	2011-10-22	Dirección 950222	Madre de MaríA	Madre	3000950222	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
157	950272	MaríA	RodríGuez	2010-10-22	Dirección 950272	Madre de MaríA	Madre	3000950272	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
158	950322	MaríA	RodríGuez	2009-10-22	Dirección 950322	Madre de MaríA	Madre	3000950322	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
159	950023	Laura	MartíNez	2015-11-23	Dirección 950023	Madre de Laura	Madre	3000950023	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
160	950073	Laura	MartíNez	2014-11-23	Dirección 950073	Madre de Laura	Madre	3000950073	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
161	950123	Laura	MartíNez	2013-11-23	Dirección 950123	Madre de Laura	Madre	3000950123	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
162	950173	Laura	MartíNez	2012-11-23	Dirección 950173	Madre de Laura	Madre	3000950173	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
163	950223	Laura	MartíNez	2011-11-23	Dirección 950223	Madre de Laura	Madre	3000950223	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
164	950273	Laura	MartíNez	2010-11-23	Dirección 950273	Madre de Laura	Madre	3000950273	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
165	950323	Laura	MartíNez	2009-11-23	Dirección 950323	Madre de Laura	Madre	3000950323	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
166	950024	Carlos	LóPez	2015-12-24	Dirección 950024	Madre de Carlos	Madre	3000950024	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
167	950074	Carlos	LóPez	2014-12-24	Dirección 950074	Madre de Carlos	Madre	3000950074	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
168	950124	Carlos	LóPez	2013-12-24	Dirección 950124	Madre de Carlos	Madre	3000950124	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
169	950174	Carlos	LóPez	2012-12-24	Dirección 950174	Madre de Carlos	Madre	3000950174	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
170	950224	Carlos	LóPez	2011-12-24	Dirección 950224	Madre de Carlos	Madre	3000950224	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
171	950274	Carlos	LóPez	2010-12-24	Dirección 950274	Madre de Carlos	Madre	3000950274	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
172	950324	Carlos	LóPez	2009-12-24	Dirección 950324	Madre de Carlos	Madre	3000950324	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
173	950025	AndréS	HernáNdez	2015-01-25	Dirección 950025	Madre de AndréS	Madre	3000950025	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
174	950075	AndréS	HernáNdez	2014-01-25	Dirección 950075	Madre de AndréS	Madre	3000950075	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
175	950125	AndréS	HernáNdez	2013-01-25	Dirección 950125	Madre de AndréS	Madre	3000950125	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
176	950175	AndréS	HernáNdez	2012-01-25	Dirección 950175	Madre de AndréS	Madre	3000950175	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
177	950225	AndréS	HernáNdez	2011-01-25	Dirección 950225	Madre de AndréS	Madre	3000950225	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
178	950275	AndréS	HernáNdez	2010-01-25	Dirección 950275	Madre de AndréS	Madre	3000950275	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
179	950325	AndréS	HernáNdez	2009-01-25	Dirección 950325	Madre de AndréS	Madre	3000950325	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
180	950026	Camila	GarcíA	2015-02-26	Dirección 950026	Madre de Camila	Madre	3000950026	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
181	950076	Camila	GarcíA	2014-02-26	Dirección 950076	Madre de Camila	Madre	3000950076	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
182	950126	Camila	GarcíA	2013-02-26	Dirección 950126	Madre de Camila	Madre	3000950126	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
183	950176	Camila	GarcíA	2012-02-26	Dirección 950176	Madre de Camila	Madre	3000950176	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
184	950226	Camila	GarcíA	2011-02-26	Dirección 950226	Madre de Camila	Madre	3000950226	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
185	950276	Camila	GarcíA	2010-02-26	Dirección 950276	Madre de Camila	Madre	3000950276	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
186	950326	Camila	GarcíA	2009-02-26	Dirección 950326	Madre de Camila	Madre	3000950326	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
187	950027	SofíA	PéRez	2015-03-27	Dirección 950027	Madre de SofíA	Madre	3000950027	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
188	950077	SofíA	PéRez	2014-03-27	Dirección 950077	Madre de SofíA	Madre	3000950077	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
189	950127	SofíA	PéRez	2013-03-27	Dirección 950127	Madre de SofíA	Madre	3000950127	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
190	950177	SofíA	PéRez	2012-03-27	Dirección 950177	Madre de SofíA	Madre	3000950177	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
191	950227	SofíA	PéRez	2011-03-27	Dirección 950227	Madre de SofíA	Madre	3000950227	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
192	950277	SofíA	PéRez	2010-03-27	Dirección 950277	Madre de SofíA	Madre	3000950277	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
193	950327	SofíA	PéRez	2009-03-27	Dirección 950327	Madre de SofíA	Madre	3000950327	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
194	950028	Mateo	SáNchez	2015-04-28	Dirección 950028	Madre de Mateo	Madre	3000950028	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
195	950078	Mateo	SáNchez	2014-04-28	Dirección 950078	Madre de Mateo	Madre	3000950078	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
196	950128	Mateo	SáNchez	2013-04-28	Dirección 950128	Madre de Mateo	Madre	3000950128	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
197	950178	Mateo	SáNchez	2012-04-28	Dirección 950178	Madre de Mateo	Madre	3000950178	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
198	950228	Mateo	SáNchez	2011-04-28	Dirección 950228	Madre de Mateo	Madre	3000950228	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
199	950278	Mateo	SáNchez	2010-04-28	Dirección 950278	Madre de Mateo	Madre	3000950278	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
200	950328	Mateo	SáNchez	2009-04-28	Dirección 950328	Madre de Mateo	Madre	3000950328	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
201	950029	Valentina	RamíRez	2015-05-01	Dirección 950029	Madre de Valentina	Madre	3000950029	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
202	950079	Valentina	RamíRez	2014-05-01	Dirección 950079	Madre de Valentina	Madre	3000950079	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
203	950129	Valentina	RamíRez	2013-05-01	Dirección 950129	Madre de Valentina	Madre	3000950129	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
204	950179	Valentina	RamíRez	2012-05-01	Dirección 950179	Madre de Valentina	Madre	3000950179	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
205	950229	Valentina	RamíRez	2011-05-01	Dirección 950229	Madre de Valentina	Madre	3000950229	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
206	950279	Valentina	RamíRez	2010-05-01	Dirección 950279	Madre de Valentina	Madre	3000950279	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
207	950329	Valentina	RamíRez	2009-05-01	Dirección 950329	Madre de Valentina	Madre	3000950329	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
208	950030	Daniel	Torres	2015-06-02	Dirección 950030	Madre de Daniel	Madre	3000950030	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
209	950080	Daniel	Torres	2014-06-02	Dirección 950080	Madre de Daniel	Madre	3000950080	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
210	950130	Daniel	Torres	2013-06-02	Dirección 950130	Madre de Daniel	Madre	3000950130	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
211	950180	Daniel	Torres	2012-06-02	Dirección 950180	Madre de Daniel	Madre	3000950180	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
212	950230	Daniel	Torres	2011-06-02	Dirección 950230	Madre de Daniel	Madre	3000950230	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
213	950280	Daniel	Torres	2010-06-02	Dirección 950280	Madre de Daniel	Madre	3000950280	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
214	950330	Daniel	Torres	2009-06-02	Dirección 950330	Madre de Daniel	Madre	3000950330	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
215	950031	Santiago	DíAz	2015-07-03	Dirección 950031	Madre de Santiago	Madre	3000950031	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
216	950081	Santiago	DíAz	2014-07-03	Dirección 950081	Madre de Santiago	Madre	3000950081	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
217	950131	Santiago	DíAz	2013-07-03	Dirección 950131	Madre de Santiago	Madre	3000950131	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
218	950181	Santiago	DíAz	2012-07-03	Dirección 950181	Madre de Santiago	Madre	3000950181	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
219	950231	Santiago	DíAz	2011-07-03	Dirección 950231	Madre de Santiago	Madre	3000950231	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
220	950281	Santiago	DíAz	2010-07-03	Dirección 950281	Madre de Santiago	Madre	3000950281	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
221	950331	Santiago	DíAz	2009-07-03	Dirección 950331	Madre de Santiago	Madre	3000950331	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
222	950032	Isabella	Vargas	2015-08-04	Dirección 950032	Madre de Isabella	Madre	3000950032	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
223	950082	Isabella	Vargas	2014-08-04	Dirección 950082	Madre de Isabella	Madre	3000950082	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
224	950132	Isabella	Vargas	2013-08-04	Dirección 950132	Madre de Isabella	Madre	3000950132	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
225	950182	Isabella	Vargas	2012-08-04	Dirección 950182	Madre de Isabella	Madre	3000950182	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
226	950232	Isabella	Vargas	2011-08-04	Dirección 950232	Madre de Isabella	Madre	3000950232	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
227	950282	Isabella	Vargas	2010-08-04	Dirección 950282	Madre de Isabella	Madre	3000950282	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
228	950332	Isabella	Vargas	2009-08-04	Dirección 950332	Madre de Isabella	Madre	3000950332	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
229	950033	Samuel	Castro	2015-09-05	Dirección 950033	Madre de Samuel	Madre	3000950033	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
230	950083	Samuel	Castro	2014-09-05	Dirección 950083	Madre de Samuel	Madre	3000950083	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
231	950133	Samuel	Castro	2013-09-05	Dirección 950133	Madre de Samuel	Madre	3000950133	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
232	950183	Samuel	Castro	2012-09-05	Dirección 950183	Madre de Samuel	Madre	3000950183	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
233	950233	Samuel	Castro	2011-09-05	Dirección 950233	Madre de Samuel	Madre	3000950233	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
234	950283	Samuel	Castro	2010-09-05	Dirección 950283	Madre de Samuel	Madre	3000950283	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
235	950333	Samuel	Castro	2009-09-05	Dirección 950333	Madre de Samuel	Madre	3000950333	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
236	950034	Juliana	Ruiz	2015-10-06	Dirección 950034	Madre de Juliana	Madre	3000950034	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
237	950084	Juliana	Ruiz	2014-10-06	Dirección 950084	Madre de Juliana	Madre	3000950084	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
238	950134	Juliana	Ruiz	2013-10-06	Dirección 950134	Madre de Juliana	Madre	3000950134	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
239	950184	Juliana	Ruiz	2012-10-06	Dirección 950184	Madre de Juliana	Madre	3000950184	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
240	950234	Juliana	Ruiz	2011-10-06	Dirección 950234	Madre de Juliana	Madre	3000950234	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
241	950284	Juliana	Ruiz	2010-10-06	Dirección 950284	Madre de Juliana	Madre	3000950284	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
242	950334	Juliana	Ruiz	2009-10-06	Dirección 950334	Madre de Juliana	Madre	3000950334	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
243	950035	NicoláS	Moreno	2015-11-07	Dirección 950035	Madre de NicoláS	Madre	3000950035	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
244	950085	NicoláS	Moreno	2014-11-07	Dirección 950085	Madre de NicoláS	Madre	3000950085	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
245	950135	NicoláS	Moreno	2013-11-07	Dirección 950135	Madre de NicoláS	Madre	3000950135	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
246	950185	NicoláS	Moreno	2012-11-07	Dirección 950185	Madre de NicoláS	Madre	3000950185	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
247	950235	NicoláS	Moreno	2011-11-07	Dirección 950235	Madre de NicoláS	Madre	3000950235	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
248	950285	NicoláS	Moreno	2010-11-07	Dirección 950285	Madre de NicoláS	Madre	3000950285	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
249	950335	NicoláS	Moreno	2009-11-07	Dirección 950335	Madre de NicoláS	Madre	3000950335	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
250	950036	Andrea	ÁLvarez	2015-12-08	Dirección 950036	Madre de Andrea	Madre	3000950036	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
251	950086	Andrea	ÁLvarez	2014-12-08	Dirección 950086	Madre de Andrea	Madre	3000950086	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
252	950136	Andrea	ÁLvarez	2013-12-08	Dirección 950136	Madre de Andrea	Madre	3000950136	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
253	950186	Andrea	ÁLvarez	2012-12-08	Dirección 950186	Madre de Andrea	Madre	3000950186	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
254	950236	Andrea	ÁLvarez	2011-12-08	Dirección 950236	Madre de Andrea	Madre	3000950236	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
255	950286	Andrea	ÁLvarez	2010-12-08	Dirección 950286	Madre de Andrea	Madre	3000950286	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
256	950336	Andrea	ÁLvarez	2009-12-08	Dirección 950336	Madre de Andrea	Madre	3000950336	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
257	950037	David	Rojas	2015-01-09	Dirección 950037	Madre de David	Madre	3000950037	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
258	950087	David	Rojas	2014-01-09	Dirección 950087	Madre de David	Madre	3000950087	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
259	950137	David	Rojas	2013-01-09	Dirección 950137	Madre de David	Madre	3000950137	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
260	950187	David	Rojas	2012-01-09	Dirección 950187	Madre de David	Madre	3000950187	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
261	950237	David	Rojas	2011-01-09	Dirección 950237	Madre de David	Madre	3000950237	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
262	950287	David	Rojas	2010-01-09	Dirección 950287	Madre de David	Madre	3000950287	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
263	950337	David	Rojas	2009-01-09	Dirección 950337	Madre de David	Madre	3000950337	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
264	950038	Paula	MuñOz	2015-02-10	Dirección 950038	Madre de Paula	Madre	3000950038	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
265	950088	Paula	MuñOz	2014-02-10	Dirección 950088	Madre de Paula	Madre	3000950088	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
266	950138	Paula	MuñOz	2013-02-10	Dirección 950138	Madre de Paula	Madre	3000950138	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
267	950188	Paula	MuñOz	2012-02-10	Dirección 950188	Madre de Paula	Madre	3000950188	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
268	950238	Paula	MuñOz	2011-02-10	Dirección 950238	Madre de Paula	Madre	3000950238	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
269	950288	Paula	MuñOz	2010-02-10	Dirección 950288	Madre de Paula	Madre	3000950288	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
270	950338	Paula	MuñOz	2009-02-10	Dirección 950338	Madre de Paula	Madre	3000950338	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
271	950039	Miguel	SuáRez	2015-03-11	Dirección 950039	Madre de Miguel	Madre	3000950039	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
272	950089	Miguel	SuáRez	2014-03-11	Dirección 950089	Madre de Miguel	Madre	3000950089	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
273	950139	Miguel	SuáRez	2013-03-11	Dirección 950139	Madre de Miguel	Madre	3000950139	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
274	950189	Miguel	SuáRez	2012-03-11	Dirección 950189	Madre de Miguel	Madre	3000950189	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
275	950239	Miguel	SuáRez	2011-03-11	Dirección 950239	Madre de Miguel	Madre	3000950239	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
276	950289	Miguel	SuáRez	2010-03-11	Dirección 950289	Madre de Miguel	Madre	3000950289	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
277	950339	Miguel	SuáRez	2009-03-11	Dirección 950339	Madre de Miguel	Madre	3000950339	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
278	950040	Gabriela	Cruz	2015-04-12	Dirección 950040	Madre de Gabriela	Madre	3000950040	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
279	950090	Gabriela	Cruz	2014-04-12	Dirección 950090	Madre de Gabriela	Madre	3000950090	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
280	950140	Gabriela	Cruz	2013-04-12	Dirección 950140	Madre de Gabriela	Madre	3000950140	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
281	950190	Gabriela	Cruz	2012-04-12	Dirección 950190	Madre de Gabriela	Madre	3000950190	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
282	950240	Gabriela	Cruz	2011-04-12	Dirección 950240	Madre de Gabriela	Madre	3000950240	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
283	950290	Gabriela	Cruz	2010-04-12	Dirección 950290	Madre de Gabriela	Madre	3000950290	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
284	950340	Gabriela	Cruz	2009-04-12	Dirección 950340	Madre de Gabriela	Madre	3000950340	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
285	950041	Juan	GóMez	2015-05-13	Dirección 950041	Madre de Juan	Madre	3000950041	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
286	950091	Juan	GóMez	2014-05-13	Dirección 950091	Madre de Juan	Madre	3000950091	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
287	950141	Juan	GóMez	2013-05-13	Dirección 950141	Madre de Juan	Madre	3000950141	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
288	950191	Juan	GóMez	2012-05-13	Dirección 950191	Madre de Juan	Madre	3000950191	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
289	950241	Juan	GóMez	2011-05-13	Dirección 950241	Madre de Juan	Madre	3000950241	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
290	950291	Juan	GóMez	2010-05-13	Dirección 950291	Madre de Juan	Madre	3000950291	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
291	950341	Juan	GóMez	2009-05-13	Dirección 950341	Madre de Juan	Madre	3000950341	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
292	950042	MaríA	RodríGuez	2015-06-14	Dirección 950042	Madre de MaríA	Madre	3000950042	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
293	950092	MaríA	RodríGuez	2014-06-14	Dirección 950092	Madre de MaríA	Madre	3000950092	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
294	950142	MaríA	RodríGuez	2013-06-14	Dirección 950142	Madre de MaríA	Madre	3000950142	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
295	950192	MaríA	RodríGuez	2012-06-14	Dirección 950192	Madre de MaríA	Madre	3000950192	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
296	950242	MaríA	RodríGuez	2011-06-14	Dirección 950242	Madre de MaríA	Madre	3000950242	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
297	950292	MaríA	RodríGuez	2010-06-14	Dirección 950292	Madre de MaríA	Madre	3000950292	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
298	950342	MaríA	RodríGuez	2009-06-14	Dirección 950342	Madre de MaríA	Madre	3000950342	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
299	950043	Laura	MartíNez	2015-07-15	Dirección 950043	Madre de Laura	Madre	3000950043	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
300	950093	Laura	MartíNez	2014-07-15	Dirección 950093	Madre de Laura	Madre	3000950093	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
301	950143	Laura	MartíNez	2013-07-15	Dirección 950143	Madre de Laura	Madre	3000950143	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
302	950193	Laura	MartíNez	2012-07-15	Dirección 950193	Madre de Laura	Madre	3000950193	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
303	950243	Laura	MartíNez	2011-07-15	Dirección 950243	Madre de Laura	Madre	3000950243	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
304	950293	Laura	MartíNez	2010-07-15	Dirección 950293	Madre de Laura	Madre	3000950293	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
305	950343	Laura	MartíNez	2009-07-15	Dirección 950343	Madre de Laura	Madre	3000950343	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
306	950044	Carlos	LóPez	2015-08-16	Dirección 950044	Madre de Carlos	Madre	3000950044	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
307	950094	Carlos	LóPez	2014-08-16	Dirección 950094	Madre de Carlos	Madre	3000950094	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
308	950144	Carlos	LóPez	2013-08-16	Dirección 950144	Madre de Carlos	Madre	3000950144	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
309	950194	Carlos	LóPez	2012-08-16	Dirección 950194	Madre de Carlos	Madre	3000950194	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
310	950244	Carlos	LóPez	2011-08-16	Dirección 950244	Madre de Carlos	Madre	3000950244	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
311	950294	Carlos	LóPez	2010-08-16	Dirección 950294	Madre de Carlos	Madre	3000950294	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
312	950344	Carlos	LóPez	2009-08-16	Dirección 950344	Madre de Carlos	Madre	3000950344	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
313	950045	AndréS	HernáNdez	2015-09-17	Dirección 950045	Madre de AndréS	Madre	3000950045	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
314	950095	AndréS	HernáNdez	2014-09-17	Dirección 950095	Madre de AndréS	Madre	3000950095	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
315	950145	AndréS	HernáNdez	2013-09-17	Dirección 950145	Madre de AndréS	Madre	3000950145	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
316	950195	AndréS	HernáNdez	2012-09-17	Dirección 950195	Madre de AndréS	Madre	3000950195	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
317	950245	AndréS	HernáNdez	2011-09-17	Dirección 950245	Madre de AndréS	Madre	3000950245	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
318	950295	AndréS	HernáNdez	2010-09-17	Dirección 950295	Madre de AndréS	Madre	3000950295	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
319	950345	AndréS	HernáNdez	2009-09-17	Dirección 950345	Madre de AndréS	Madre	3000950345	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
320	950046	Camila	GarcíA	2015-10-18	Dirección 950046	Madre de Camila	Madre	3000950046	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
321	950096	Camila	GarcíA	2014-10-18	Dirección 950096	Madre de Camila	Madre	3000950096	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
322	950146	Camila	GarcíA	2013-10-18	Dirección 950146	Madre de Camila	Madre	3000950146	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
323	950196	Camila	GarcíA	2012-10-18	Dirección 950196	Madre de Camila	Madre	3000950196	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
324	950246	Camila	GarcíA	2011-10-18	Dirección 950246	Madre de Camila	Madre	3000950246	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
325	950296	Camila	GarcíA	2010-10-18	Dirección 950296	Madre de Camila	Madre	3000950296	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
326	950346	Camila	GarcíA	2009-10-18	Dirección 950346	Madre de Camila	Madre	3000950346	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
327	950047	SofíA	PéRez	2015-11-19	Dirección 950047	Madre de SofíA	Madre	3000950047	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
328	950097	SofíA	PéRez	2014-11-19	Dirección 950097	Madre de SofíA	Madre	3000950097	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
329	950147	SofíA	PéRez	2013-11-19	Dirección 950147	Madre de SofíA	Madre	3000950147	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
330	950197	SofíA	PéRez	2012-11-19	Dirección 950197	Madre de SofíA	Madre	3000950197	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
331	950247	SofíA	PéRez	2011-11-19	Dirección 950247	Madre de SofíA	Madre	3000950247	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
332	950297	SofíA	PéRez	2010-11-19	Dirección 950297	Madre de SofíA	Madre	3000950297	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
333	950347	SofíA	PéRez	2009-11-19	Dirección 950347	Madre de SofíA	Madre	3000950347	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
334	950048	Mateo	SáNchez	2015-12-20	Dirección 950048	Madre de Mateo	Madre	3000950048	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
335	950098	Mateo	SáNchez	2014-12-20	Dirección 950098	Madre de Mateo	Madre	3000950098	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
336	950148	Mateo	SáNchez	2013-12-20	Dirección 950148	Madre de Mateo	Madre	3000950148	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
337	950198	Mateo	SáNchez	2012-12-20	Dirección 950198	Madre de Mateo	Madre	3000950198	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
338	950248	Mateo	SáNchez	2011-12-20	Dirección 950248	Madre de Mateo	Madre	3000950248	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
339	950298	Mateo	SáNchez	2010-12-20	Dirección 950298	Madre de Mateo	Madre	3000950298	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
340	950348	Mateo	SáNchez	2009-12-20	Dirección 950348	Madre de Mateo	Madre	3000950348	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
341	950049	Valentina	RamíRez	2015-01-21	Dirección 950049	Madre de Valentina	Madre	3000950049	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
342	950099	Valentina	RamíRez	2014-01-21	Dirección 950099	Madre de Valentina	Madre	3000950099	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
343	950149	Valentina	RamíRez	2013-01-21	Dirección 950149	Madre de Valentina	Madre	3000950149	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
344	950199	Valentina	RamíRez	2012-01-21	Dirección 950199	Madre de Valentina	Madre	3000950199	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
345	950249	Valentina	RamíRez	2011-01-21	Dirección 950249	Madre de Valentina	Madre	3000950249	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
346	950299	Valentina	RamíRez	2010-01-21	Dirección 950299	Madre de Valentina	Madre	3000950299	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
347	950349	Valentina	RamíRez	2009-01-21	Dirección 950349	Madre de Valentina	Madre	3000950349	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
348	950050	Daniel	Torres	2015-02-22	Dirección 950050	Madre de Daniel	Madre	3000950050	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
349	950100	Daniel	Torres	2014-02-22	Dirección 950100	Madre de Daniel	Madre	3000950100	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
350	950150	Daniel	Torres	2013-02-22	Dirección 950150	Madre de Daniel	Madre	3000950150	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
351	950200	Daniel	Torres	2012-02-22	Dirección 950200	Madre de Daniel	Madre	3000950200	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
352	950250	Daniel	Torres	2011-02-22	Dirección 950250	Madre de Daniel	Madre	3000950250	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
353	950300	Daniel	Torres	2010-02-22	Dirección 950300	Madre de Daniel	Madre	3000950300	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
354	950350	Daniel	Torres	2009-02-22	Dirección 950350	Madre de Daniel	Madre	3000950350	t	2026-03-09 20:02:55.916684+01	2026-03-09 20:02:55.916684+01	\N	No Binario
\.


--
-- Data for Name: subject_areas; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.subject_areas (area_id, name, code, is_specialization) FROM stdin;
1	Matematicas	MAT	f
3	Humanidades	HUM	f
4	Educacion Artistica	EA	f
5	Ciencias Sociales	CS	f
6	Ciencias Naturales	CN	f
7	Educacion Fisica	EF	f
8	Tecnologia e Informatica	TEI	f
9	Especializacion Deportes	ED	t
10	Especializacion Sistemas	ES	t
12	Sin Especializacion	SE	t
11	Espacializacion Economia	EE	t
\.


--
-- Data for Name: subjects; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.subjects (subject_id, area_id, subject_code, name, description, created_at) FROM stdin;
1	1	MAT_G	Geometria	Para algo sirve.	2026-02-17 22:51:27.404699+01
2	3	HUM_I	Ingles	Segunda Lengua.	2026-02-17 22:51:49.085771+01
3	6	CN_N	Naturales	\N	2026-02-24 20:36:14.762926+01
4	5	CS_S	Sociales	\N	2026-02-24 20:36:35.455037+01
5	5	CS_E	Etica	\N	2026-02-24 20:36:53.396522+01
6	5	CS_ER	Educacion Religiosa	\N	2026-02-24 20:37:07.400349+01
7	3	HUM_E	Espanol	\N	2026-02-24 20:37:38.794794+01
9	3	HUM_LC	Lectura Critica	\N	2026-02-24 20:38:02.118143+01
10	7	EF_EF	Educacion Fisica	\N	2026-02-24 20:38:30.60685+01
11	1	MAT_M	Matematicas	\N	2026-02-24 20:38:53.336633+01
12	4	EA_M	Musica	\N	2026-02-24 20:39:56.045551+01
13	4	EA_A	Artes	\N	2026-02-24 20:40:02.684729+01
14	6	CN_Q	Quimica	\N	2026-02-24 20:40:16.130583+01
15	6	CN_F	Fisica	\N	2026-02-24 20:40:22.48296+01
16	8	TEI_T	Tecnologia	\N	2026-02-24 20:40:46.772993+01
17	8	TEI_I	Informatica	\N	2026-02-24 20:40:58.65071+01
18	11	EE_E	Emprendimiento	\N	2026-02-24 20:43:14.478314+01
20	5	CS_F	Filosofia	\N	2026-02-24 21:08:18.371951+01
22	5	CS_EC	Economia	\N	2026-02-24 23:52:50.309907+01
23	1	MAT_E	Estadistica	\N	2026-02-24 23:53:12.035691+01
24	9	ED_CR	Cultura Recreativa	\N	2026-02-24 23:53:38.868123+01
25	9	ED_M	Metodologia	\N	2026-02-24 23:53:49.683268+01
26	9	ED_CD	Cultura Deportiva	\N	2026-02-24 23:54:01.811681+01
27	9	ED_S	SENA	\N	2026-02-24 23:54:15.584176+01
28	9	ED_DH	Desarrollo Humano	\N	2026-02-24 23:54:53.191637+01
29	9	ED_SYG	Sistema y Gestion	\N	2026-02-24 23:55:14.293434+01
30	9	ED_PD	Practica Deportiva	\N	2026-02-24 23:55:26.785701+01
31	9	ED_FP	Fundamentos Pedagogicos	\N	2026-02-24 23:55:54.253816+01
32	10	ES_PM	Procesos Mecanicos	\N	2026-02-24 23:56:23.319798+01
33	10	ES_DI	Diseno Industrial 	\N	2026-02-24 23:56:51.006678+01
34	10	ES_M	Microcontroladores	\N	2026-02-24 23:57:03.649552+01
35	10	ES_PL	PLC	\N	2026-02-24 23:57:10.338336+01
37	10	ES_S	Sena	\N	2026-02-24 23:57:49.984448+01
38	10	ES_ME	Metodologia	\N	2026-02-24 23:58:00.382268+01
39	10	ES_E	Electronica	\N	2026-02-24 23:58:12.804983+01
40	10	ES_CA	Control Analogico	\N	2026-02-24 23:58:48.336787+01
41	10	ES_N	Neumatica	\N	2026-02-24 23:58:58.221156+01
43	11	EE_C	Contabilidad	\N	2026-02-25 00:00:07.540691+01
44	11	EE_S	SENA	\N	2026-02-25 00:00:20.929299+01
45	11	EE_MF	Matematica Financiera	\N	2026-02-25 00:00:35.405084+01
46	11	EE_M	Metodologia	\N	2026-02-25 00:00:42.499464+01
47	11	EE_EE	Estadistica Empresarial	\N	2026-02-25 00:00:54.735935+01
48	11	EE_PYM	Publicidad y Mercadeo	\N	2026-02-25 00:01:10.272056+01
49	11	EE_LT	Legislacion Tributaria	\N	2026-02-25 00:01:26.171213+01
50	11	EE_LL	Legislacion Laboral	\N	2026-02-25 00:01:41.840047+01
51	11	EE_PC	Paquete Contable	\N	2026-02-25 00:02:00.031154+01
52	5	CS_CP	Ciencias Politicas	\N	2026-02-25 00:02:22.249294+01
53	12	SE_S	Sena	\N	2026-02-25 00:04:02.202468+01
54	8	TEI_P	Programacion	\N	2026-02-28 11:46:38.810438+01
55	10	ES_P	Programacion	\N	2026-02-28 11:56:03.036229+01
56	3	HUM_EM	Emprendimiento	\N	2026-02-28 12:08:41.838561+01
\.


--
-- Data for Name: teacher_subjects; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.teacher_subjects (teacher_subject_id, teacher_id, subject_id, created_at) FROM stdin;
2	100100	1	2026-02-18 18:58:39.232937+01
4	000001	10	2026-02-24 20:56:38.185975+01
5	000002	10	2026-02-24 20:57:30.241439+01
6	000003	10	2026-02-24 20:58:07.170063+01
7	000004	10	2026-02-24 20:58:40.768478+01
8	000005	2	2026-02-24 20:59:31.464552+01
9	000005	7	2026-02-24 20:59:31.472896+01
10	000005	9	2026-02-24 20:59:31.473872+01
11	000006	17	2026-02-24 21:00:39.359464+01
12	000006	14	2026-02-24 21:00:39.367594+01
14	000006	15	2026-02-24 21:00:39.368412+01
15	000006	3	2026-02-24 21:00:39.369215+01
16	000006	16	2026-02-24 21:00:39.369514+01
17	000007	2	2026-02-24 21:04:25.305277+01
18	000007	9	2026-02-24 21:04:25.306175+01
19	000007	7	2026-02-24 21:04:25.306237+01
20	000008	12	2026-02-24 21:05:10.3387+01
21	000008	13	2026-02-24 21:05:10.347535+01
22	000009	7	2026-02-24 21:06:51.28462+01
23	000009	2	2026-02-24 21:06:51.289195+01
24	000009	9	2026-02-24 21:06:51.289255+01
26	000010	5	2026-02-24 21:07:36.258794+01
25	000010	6	2026-02-24 21:07:36.25869+01
27	000010	4	2026-02-24 21:07:36.258745+01
28	000011	6	2026-02-24 21:09:19.131052+01
29	000011	4	2026-02-24 21:09:19.14186+01
30	000011	20	2026-02-24 21:09:19.142133+01
31	000011	5	2026-02-24 21:09:19.142826+01
32	000012	18	2026-02-24 21:13:31.202723+01
33	000013	3	2026-02-24 21:18:09.41598+01
34	000013	15	2026-02-24 21:18:09.427572+01
35	000013	11	2026-02-24 21:18:09.428783+01
36	000013	14	2026-02-24 21:18:09.429966+01
37	000013	1	2026-02-24 21:18:09.431226+01
38	000014	6	2026-02-24 21:35:12.990918+01
39	000014	4	2026-02-24 21:35:12.998886+01
40	000014	20	2026-02-24 21:35:13.001555+01
41	000014	5	2026-02-24 21:35:13.002817+01
42	000015	14	2026-02-24 21:36:06.42911+01
43	000015	3	2026-02-24 21:36:06.429452+01
44	000015	15	2026-02-24 21:36:06.429884+01
46	000016	12	2026-02-24 21:40:05.144599+01
45	000016	13	2026-02-24 21:40:05.144501+01
47	000017	7	2026-02-24 21:40:34.079553+01
48	000017	2	2026-02-24 21:40:34.08154+01
49	000017	9	2026-02-24 21:40:34.081803+01
51	000018	7	2026-02-24 21:41:12.136887+01
50	000018	2	2026-02-24 21:41:12.136982+01
52	000018	9	2026-02-24 21:41:12.137044+01
54	000019	11	2026-02-24 21:41:51.286173+01
53	000019	1	2026-02-24 21:41:51.286092+01
55	000020	15	2026-02-24 21:42:46.934054+01
56	000020	14	2026-02-24 21:42:46.934132+01
57	000020	3	2026-02-24 21:42:46.934427+01
58	000021	7	2026-02-24 21:43:43.15987+01
59	000021	9	2026-02-24 21:43:43.160091+01
60	000021	2	2026-02-24 21:43:43.160488+01
61	000022	1	2026-02-24 21:45:59.273017+01
62	000022	11	2026-02-24 21:45:59.272928+01
63	000023	7	2026-02-24 21:47:53.536451+01
64	000023	9	2026-02-24 21:47:53.545188+01
65	000023	2	2026-02-24 21:47:53.545324+01
68	000024	17	2026-02-24 21:48:29.230842+01
66	000024	16	2026-02-24 21:48:29.230367+01
69	000025	15	2026-02-24 21:48:57.159945+01
70	000025	3	2026-02-24 21:48:57.160484+01
71	000025	14	2026-02-24 21:48:57.161132+01
73	000026	7	2026-02-24 21:49:31.629271+01
72	000026	9	2026-02-24 21:49:31.629186+01
74	000026	2	2026-02-24 21:49:31.62959+01
75	000027	17	2026-02-24 21:50:04.063864+01
76	000027	2	2026-02-24 21:50:04.070554+01
77	000027	7	2026-02-24 21:50:04.071033+01
78	000027	9	2026-02-24 21:50:04.070973+01
79	000027	16	2026-02-24 21:50:04.071569+01
81	000028	17	2026-02-24 21:51:15.811647+01
80	000028	16	2026-02-24 21:51:15.811516+01
83	000029	1	2026-02-24 21:53:10.615492+01
82	000029	11	2026-02-24 21:53:10.615393+01
85	000030	7	2026-02-24 21:53:58.842044+01
84	000030	9	2026-02-24 21:53:58.842106+01
86	000030	2	2026-02-24 21:53:58.84216+01
87	000031	5	2026-02-24 21:54:40.299462+01
88	000031	6	2026-02-24 21:54:40.306005+01
89	000031	4	2026-02-24 21:54:40.306428+01
90	000031	20	2026-02-24 21:54:40.306776+01
92	000032	14	2026-02-24 21:55:49.102766+01
94	00033	6	2026-02-24 21:59:30.420198+01
95	00033	4	2026-02-24 21:59:30.4208+01
96	00033	20	2026-02-24 21:59:30.421273+01
97	00033	5	2026-02-24 21:59:30.42146+01
98	000034	1	2026-02-24 21:59:59.910275+01
99	000034	11	2026-02-24 21:59:59.91061+01
100	000035	11	2026-02-24 22:01:08.873295+01
101	000035	1	2026-02-24 22:01:08.873383+01
102	000036	9	2026-02-24 22:01:44.212396+01
103	000036	4	2026-02-24 22:01:44.216581+01
104	000036	6	2026-02-24 22:01:44.216775+01
105	000036	7	2026-02-24 22:01:44.218209+01
106	000036	5	2026-02-24 22:01:44.218448+01
107	000036	20	2026-02-24 22:01:44.219387+01
108	000036	2	2026-02-24 22:01:44.220303+01
109	000037	9	2026-02-24 22:02:58.614741+01
110	000037	7	2026-02-24 22:02:58.614683+01
111	000037	2	2026-02-24 22:02:58.614785+01
112	000038	16	2026-02-24 22:03:29.719333+01
114	000038	17	2026-02-24 22:03:29.72005+01
115	000039	1	2026-02-24 22:04:26.221565+01
116	000039	11	2026-02-24 22:04:26.221495+01
117	000003	24	2026-02-28 11:38:56.055664+01
118	000002	25	2026-02-28 11:40:01.123882+01
119	000001	25	2026-02-28 11:40:11.994588+01
120	000001	26	2026-02-28 11:40:32.255349+01
121	000004	31	2026-02-28 11:41:26.925283+01
122	000001	30	2026-02-28 11:42:04.450455+01
123	000003	29	2026-02-28 11:42:33.641842+01
131	000032	3	2026-03-14 18:08:11.803253+01
132	950001	54	2026-03-14 18:26:36.751878+01
133	000021	18	2026-03-14 18:27:17.903819+01
135	000009	56	2026-03-14 18:39:48.490536+01
\.


--
-- Data for Name: terms; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.terms (term_id, school_year_id, name, start_date, end_date, sort_order, is_final, created_at) FROM stdin;
\.


--
-- Data for Name: timetable_assignments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.timetable_assignments (assignment_id, course_id, slot_id, classroom_id, created_at, teacher_id, class_group_id) FROM stdin;
\.


--
-- Data for Name: timetable_slots; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.timetable_slots (slot_id, day_of_week, start_time, end_time, duration_minutes, division) FROM stdin;
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.users (national_id, username, password_hash, role, first_name, last_name, email, phone, is_active, created_at, updated_at, must_change_password, temp_password_issued_at) FROM stdin;
900100	admin.user	$2b$10$xeZPFsulAgPKEJYrLpCVmOKSMi8AH6G5mxhshSvlraAIUvS0k2Plq	admin	Maria	Lopez	maria.lopez@example.edu	+57 3001234567	t	2026-02-17 00:01:30.572015+01	2026-02-17 00:01:30.572015+01	f	\N
100100	100100	$2b$10$CpV0jkvd.cubVr1kBqDg9udwRiuWkbnThGfB882f//ULWP6fm8TVS	teacher	Campo	Elias	\N	\N	t	2026-02-17 21:51:14.874882+01	2026-02-17 21:51:14.874882+01	f	\N
000001	000001	$2b$10$Ajuy/DVZRS9ZJAxBpm4u7Ok9N66Z/acBBU/8Mb1AX.6HHN20RYSzW	teacher	Aladino	Baloncesto	\N	\N	t	2026-02-24 20:56:38.17205+01	2026-02-24 20:56:38.17205+01	f	\N
000002	000002	$2b$10$LglPHYX0Yv8olbkRCSC5meKpkY1AIvLASP/VTzvUV5wQB3Xi/FJfC	teacher	Sergio	Futbol	\N	\N	t	2026-02-24 20:57:30.217365+01	2026-02-24 20:57:30.217365+01	f	\N
000003	000003	$2b$10$8n.DRYlWEL2upG3iYkXBeOL.bFkR8I7zz0Nb0Zd5Of/HWsXx6ipwS	teacher	Henry	Micro	\N	\N	t	2026-02-24 20:58:07.147255+01	2026-02-24 20:58:07.147255+01	f	\N
000004	000004	$2b$10$XJjkQEZ0VXl1.z39AGp9peS0pyGalGbSQi.iZntAFo.9axzcaar82	teacher	Juan	Carlos	\N	\N	t	2026-02-24 20:58:40.753721+01	2026-02-24 20:58:40.753721+01	f	\N
000005	000005	$2b$10$v2bonqoxTEc.xgExMVGCxOjMzqGd9gtEOrVzczHh5l2J9MeCQiAmu	teacher	Alba	Rocio	\N	\N	t	2026-02-24 20:59:31.450023+01	2026-02-24 20:59:31.450023+01	f	\N
000006	000006	$2b$10$2/5irxEwP1Nk5xn9YJr9s.k7py3/W/0IJ51pucwTfzRLpvLoA.aQe	teacher	Carlos	Cristancho	\N	\N	t	2026-02-24 21:00:39.340421+01	2026-02-24 21:00:39.340421+01	f	\N
000007	000007	$2b$10$eOcYH8nPrl.QgWoDV/R6JOiXaVM445k7MUA/wlb89vBUFWDFzXxpK	teacher	Carolina	Parra	\N	\N	t	2026-02-24 21:04:25.281844+01	2026-02-24 21:04:25.281844+01	f	\N
000008	000008	$2b$10$Ty35IAmhot/R.mWrFAMyNuADgIG0GBgxU6ZL3zoCuMO5nWDr74CCq	teacher	Daniel	Acero	\N	\N	t	2026-02-24 21:05:10.326153+01	2026-02-24 21:05:10.326153+01	f	\N
000009	000009	$2b$10$mGZehWnptpbHCO4P.pTbHe5JKrgdqVzkvi//CLVkNVDo2KjBbtF9.	teacher	Dario	Moncayo	\N	\N	t	2026-02-24 21:06:51.265983+01	2026-02-24 21:06:51.265983+01	f	\N
000010	000010	$2b$10$R81wHpY6TpS5ev0OJXFxUeSQAQpqJ2w3MA7qUWzbz3FKt2fKW9NVy	teacher	Debbie	Delgado	\N	\N	t	2026-02-24 21:07:36.237091+01	2026-02-24 21:07:36.237091+01	f	\N
000011	000011	$2b$10$7E9fBtrQatze6S4iIBIyVe3dcaroQRr6WdrrGA4asXfn5/5mV6qU.	teacher	Deysi	Constansa	\N	\N	t	2026-02-24 21:09:19.110305+01	2026-02-24 21:09:19.110305+01	f	\N
000012	000012	$2b$10$3lkDywIitdQ8h/pxRJNks.7zku9kpfUmTiIC2a4wpjLkiqF5hpYdG	teacher	Tatiana	Triana	\N	\N	t	2026-02-24 21:13:31.183458+01	2026-02-24 21:13:31.183458+01	f	\N
000013	000013	$2b$10$7ldwFHkyAgw8dzgITSVm3u8rnXkMaTxuJSkNOWI04BBD786xTBoVG	teacher	Erick	Ortiz	\N	\N	t	2026-02-24 21:18:09.390186+01	2026-02-24 21:18:09.390186+01	f	\N
000014	000014	$2b$10$crBo6XwB02zkh.UAj1BVkejpH1s2iGUKLGv5INg18E6c4QjV8XqSW	teacher	Estiven	Perez	\N	\N	t	2026-02-24 21:35:12.969082+01	2026-02-24 21:35:12.969082+01	f	\N
000015	000015	$2b$10$63q1v/pLNz1/UC7vBEzsveEaxTvcVyobNxPP0CZhTo.IFeTtvI.1m	teacher	Gilma	Lopez	\N	\N	t	2026-02-24 21:36:06.403756+01	2026-02-24 21:36:06.403756+01	f	\N
000016	000016	$2b$10$4nt7bYhcqUldzRu7.qo01.NCMfWJ0iuEpDVbx.agigUmq/b2P5.4m	teacher	Guillermo	Amezquita	\N	\N	t	2026-02-24 21:40:05.115537+01	2026-02-24 21:40:05.115537+01	f	\N
000017	000017	$2b$10$T460lNAcW9usay3pEbEuj.7KsiBUPl0TCOPBjTgr8N5848IZBZIGe	teacher	Helman	Cabieles	\N	\N	t	2026-02-24 21:40:34.055707+01	2026-02-24 21:40:34.055707+01	f	\N
000018	000018	$2b$10$z31bSyiYthSsZQsGo/ABheIGI./d/SQ9aRLSXNKWSj9d381BbOV4W	teacher	Jazmin	Hernandez	\N	\N	t	2026-02-24 21:41:12.110933+01	2026-02-24 21:41:12.110933+01	f	\N
000019	000019	$2b$10$mYqtD0B9cbTjGo5M3srg6.pBiXrN6KAKp9VndLWJibDvvQalKShxa	teacher	Jhon	Guarin	\N	\N	t	2026-02-24 21:41:51.261175+01	2026-02-24 21:41:51.261175+01	f	\N
000020	000020	$2b$10$SI3./ptZ6VRwowTLtL0vnuc6cz.4iHBosKHEF7OHAaGWpcekqV0fy	teacher	Fernando	Hernandez	\N	\N	t	2026-02-24 21:42:46.908139+01	2026-02-24 21:42:46.908139+01	f	\N
000021	000021	$2b$10$ZJCD.kpwKWjt5rgFUteVAO2WlIwr5He4WI32T6C8g0IvSayapQA6S	teacher	Julio	Fernandez	\N	\N	t	2026-02-24 21:43:43.134483+01	2026-02-24 21:43:43.134483+01	f	\N
000022	000022	$2b$10$Y792WcXek7MvmIYf6yIxI.t/d2BEyODzCuQfShHQ7FNkx.0izUsru	teacher	Lenin	Mora	\N	\N	t	2026-02-24 21:45:59.248667+01	2026-02-24 21:45:59.248667+01	f	\N
000023	000023	$2b$10$OH7wuEMT9nmwJQTCogIKtOSh0VSQ6OBY7qi2uQkakoNpHfqgs3wh.	teacher	Leonardo	Correa	\N	\N	t	2026-02-24 21:47:53.513638+01	2026-02-24 21:47:53.513638+01	f	\N
000024	000024	$2b$10$iR9x28elpcA2tpO/T8l58.MY0FBba2kyrW8O5R1xf0yk20uBfuMfm	teacher	Lidia	Becerra	\N	\N	t	2026-02-24 21:48:29.203473+01	2026-02-24 21:48:29.203473+01	f	\N
000025	000025	$2b$10$HBQodjgt/MZlJnQCm8w.t.xXoK5BUQ/E91/untPn8C5HIcTSmq/o.	teacher	Ligia	Arevalo	\N	\N	t	2026-02-24 21:48:57.137342+01	2026-02-24 21:48:57.137342+01	f	\N
000026	000026	$2b$10$CqSAyDTWRF0Bd46vPoaTmugzeT0hlocOVxOBQsm4fuPketSVfcco6	teacher	Aleida	Cuesta	\N	\N	t	2026-02-24 21:49:31.596955+01	2026-02-24 21:49:31.596955+01	f	\N
000027	000027	$2b$10$95L29U8CbANDS0VcaUbyxuhYig.fs5ijl9LNXdKUvVc/RsKvV4DyW	teacher	Marina	Chinchilla	\N	\N	t	2026-02-24 21:50:04.045019+01	2026-02-24 21:50:04.045019+01	f	\N
000028	000028	$2b$10$0PJQaHZLt2P8k5tiUpl4TOylC4k4yy6batpWVTwKicw5RbvUkkeOG	teacher	Martha	Carrilo	\N	\N	t	2026-02-24 21:51:15.785731+01	2026-02-24 21:51:15.785731+01	f	\N
000029	000029	$2b$10$JSp5I5BmkXSCKAclDgzMgeID0hLFLYxSVsMifnm25V4oq8ynai4oq	teacher	Mauricio	Medina	\N	\N	t	2026-02-24 21:53:10.588022+01	2026-02-24 21:53:10.588022+01	f	\N
000030	000030	$2b$10$vjjC8.vEF3fafeHN3YBe/eyU5/D/yC9IoZFWYH44tyslx0TuNiaQS	teacher	Marlen	Vargas	\N	\N	t	2026-02-24 21:53:58.816059+01	2026-02-24 21:53:58.816059+01	f	\N
000031	000031	$2b$10$f/0ouItGpPxxgECj9dr8.u7UmY8Cylz9Knn4D8lIa45kz2/m5BRoy	teacher	Nancy	Ochoa	\N	\N	t	2026-02-24 21:54:40.280203+01	2026-02-24 21:54:40.280203+01	f	\N
000032	000032	$2b$10$vXuJU.iRH.khwoK0qBlo3uszSGtfAqqo3joFzY6eKIJaHH/tjOuKO	teacher	Nelcy	Hernandez	\N	\N	t	2026-02-24 21:55:49.076362+01	2026-02-24 21:55:49.076362+01	f	\N
00033	00033	$2b$10$SXm/51MIY7RE/8x6bCjaT.HQ.1p7urmNUP8QTSWCl90.Lqu2aOSai	teacher	Nubia	Otalora	\N	\N	t	2026-02-24 21:59:30.383095+01	2026-02-24 21:59:30.383095+01	f	\N
000034	000034	$2b$10$o7ansD.rpvDkoxgPvao/8ehvtqxfcfeuKVvK8fm6gpJY83CqzDEHW	teacher	Pablo	Raba	\N	\N	t	2026-02-24 21:59:59.886438+01	2026-02-24 21:59:59.886438+01	f	\N
000035	000035	$2b$10$NOKltJFot8vj28m4qCZNQOUfPJVCuY3FtpjIXZykxj09ycnWzWb7G	teacher	Patricia	Torres	\N	\N	t	2026-02-24 22:01:08.847223+01	2026-02-24 22:01:08.847223+01	f	\N
000036	000036	$2b$10$5KySsnH4rpXcFdwnEJGNkezj3h3cRlzZeM/pykrPw.BVl17etuWIy	teacher	Robinson	Reyes	\N	\N	t	2026-02-24 22:01:44.179331+01	2026-02-24 22:01:44.179331+01	f	\N
000037	000037	$2b$10$zQHhnyYarwj6V/f27MwRbO3VSpCqBrN5ilp2E4TgjCn1ElGq9NH0S	teacher	Sonia	Rojas	\N	\N	t	2026-02-24 22:02:58.59203+01	2026-02-24 22:02:58.59203+01	f	\N
000038	000038	$2b$10$OzSQ1t/vrde3AAZhIZoKdu0h.bmIL6d1dz.BmKILN9bNkx1eFFXw.	teacher	Victor	Camargo	\N	\N	t	2026-02-24 22:03:29.698322+01	2026-02-24 22:03:29.698322+01	f	\N
000039	000039	$2b$10$BklLZyUxlx1QqT4vTy7XYugTnjkOzmMtU2Tl2C9jtDteZNq4OAAxy	teacher	Yolima	Pullido	\N	\N	t	2026-02-24 22:04:26.198359+01	2026-02-24 22:04:26.198359+01	f	\N
1000001	juan.perez	$2b$10$PdMH2hx3yCaVgaERJaxAaOQWS4YnGBxXCyo8caQJlLfXVfK0zhA3q	teacher	Juan Carlos	PÃ©rez GÃ³mez	juan.perez@colegio.edu	3001234567	t	2026-03-09 21:36:35.641494+01	2026-03-09 21:36:35.641494+01	t	2026-03-09 21:36:35.637+01
1000002	maria.rodriguez	$2b$10$0pxVU90NjYaNQnURZAM.je70dHIlrYvGdSP9X6r4kkh5DZaZidU2.	teacher	MarÃ­a Fernanda	RodrÃ­guez LÃ³pez	maria.rodriguez@colegio.edu	3001234568	t	2026-03-09 21:36:35.721835+01	2026-03-09 21:36:35.721835+01	t	2026-03-09 21:36:35.72+01
1000003	camila.suarez	$2b$10$TKKepZ/YbrcF/13mYN57wejZnXrI4IZoBexsHyaIahDcqTpdI6pu2	teacher	Camila	SuÃ¡rez DÃ­az	camila.suarez@colegio.edu	3001234569	t	2026-03-09 21:36:35.790254+01	2026-03-09 21:36:35.790254+01	t	2026-03-09 21:36:35.789+01
1000004	santiago.ramirez	$2b$10$WNAQhsQUiZZ3p2hnXkdOseGvkBo89GqDTdH.Mo1z/.TWXEaIk2ZrG	teacher	Santiago	RamÃ­rez Torres	santiago.ramirez@colegio.edu	3001234570	t	2026-03-09 21:36:35.861809+01	2026-03-09 21:36:35.861809+01	t	2026-03-09 21:36:35.86+01
1000005	valentina.castro	$2b$10$IocTV7ZmaPaS3YHqWcDmwOlv63hiNshpRI7msOLD86GEymFjKLc66	teacher	Valentina	Castro Ruiz	valentina.castro@colegio.edu	3001234571	t	2026-03-09 21:36:35.933656+01	2026-03-09 21:36:35.933656+01	t	2026-03-09 21:36:35.93+01
1000006	andres.moreno	$2b$10$fYpn7mxszOprc9QpI0Xc5eRCo9WS4zOcZptv2wjc6qcoF84pgXnFi	teacher	AndrÃ©s	Moreno Ãlvarez	andres.moreno@colegio.edu	3001234572	t	2026-03-09 21:36:36.0056+01	2026-03-09 21:36:36.0056+01	t	2026-03-09 21:36:36.004+01
1000007	isabella.munoz	$2b$10$xzaZ1fVf7TSMpvmRSWe8N.pXA/o95lyLJG32TRhUiXcdz7UdPRcQq	teacher	Isabella	MuÃ±oz Cruz	isabella.munoz@colegio.edu	3001234573	t	2026-03-09 21:36:36.075478+01	2026-03-09 21:36:36.075478+01	t	2026-03-09 21:36:36.074+01
1000008	nicolas.garcia	$2b$10$.02kQn/ZWAwacYOxo79LoOEpWBvYvE3FVYkU1m2DjI2cryMzFhWNe	teacher	NicolÃ¡s	GarcÃ­a Vargas	nicolas.garcia@colegio.edu	3001234574	t	2026-03-09 21:36:36.144026+01	2026-03-09 21:36:36.144026+01	t	2026-03-09 21:36:36.142+01
1000009	sofia.martinez	$2b$10$6Eln/44j8yb3tyIYYCPNce9rneP9.PWBBfZ1bAIFuZOV0nvDgUiHq	teacher	SofÃ­a	MartÃ­nez Rojas	sofia.martinez@colegio.edu	3001234575	t	2026-03-09 21:36:36.213168+01	2026-03-09 21:36:36.213168+01	t	2026-03-09 21:36:36.211+01
1000010	daniel.hernandez	$2b$10$ckAYVfCka6mlOz93M/k/1elSmBv5x145yD3F36vs8tzC.WuYIhuMe	teacher	Daniel	HernÃ¡ndez SÃ¡nchez	daniel.hernandez@colegio.edu	3001234576	t	2026-03-09 21:36:36.282989+01	2026-03-09 21:36:36.282989+01	t	2026-03-09 21:36:36.281+01
950002	budash2325	$2b$10$FRr4dv3CW50x4bqGmcNEZuS4XWpUiR9L/DrUelMlyxsqa6MQFcaX2	teacher	Esteban	Medina	budash2325@gmail.com	3002223344	t	2026-03-12 16:52:37.295261+01	2026-03-12 16:52:37.295261+01	t	2026-03-12 16:52:37.292+01
950001	dornyei.r	$2b$10$wCPPrp3TMOstkJX6Lu7CyuTvyw5/haYQOTraSIHUHnpUiWWUn7taC	teacher	Regina	Dornyei	dornyei.r@gmail.com	3001112233	t	2026-03-12 16:52:35.947767+01	2026-03-12 16:57:52.513+01	f	\N
\.


--
-- Name: attendance_attendance_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.attendance_attendance_id_seq', 62, true);


--
-- Name: audit_logs_audit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.audit_logs_audit_id_seq', 1, false);


--
-- Name: buildings_building_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.buildings_building_id_seq', 6, true);


--
-- Name: class_group_curriculum_overrides_override_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.class_group_curriculum_overrides_override_id_seq', 1, false);


--
-- Name: class_group_fixed_locations_fixed_location_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.class_group_fixed_locations_fixed_location_id_seq', 1, false);


--
-- Name: class_groups_class_group_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.class_groups_class_group_id_seq', 5, true);


--
-- Name: classrooms_classroom_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.classrooms_classroom_id_seq', 52, true);


--
-- Name: course_instances_course_instance_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.course_instances_course_instance_id_seq', 15, true);


--
-- Name: courses_course_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.courses_course_id_seq', 75, true);


--
-- Name: curricula_curriculum_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.curricula_curriculum_id_seq', 10, true);


--
-- Name: curriculum_items_curriculum_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.curriculum_items_curriculum_item_id_seq', 199, true);


--
-- Name: disciplinary_records_disciplinary_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.disciplinary_records_disciplinary_id_seq', 1, false);


--
-- Name: enrollments_enrollment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.enrollments_enrollment_id_seq', 354, true);


--
-- Name: grade_scheme_values_value_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.grade_scheme_values_value_id_seq', 1, false);


--
-- Name: grade_schemes_scheme_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.grade_schemes_scheme_id_seq', 1, false);


--
-- Name: grades_grade_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.grades_grade_id_seq', 1, false);


--
-- Name: migrations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.migrations_id_seq', 22, true);


--
-- Name: notifications_notification_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.notifications_notification_id_seq', 1, false);


--
-- Name: planilla_sheets_planilla_sheet_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.planilla_sheets_planilla_sheet_id_seq', 29, true);


--
-- Name: print_generation_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.print_generation_seq', 3, true);


--
-- Name: school_years_school_year_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.school_years_school_year_id_seq', 1, true);


--
-- Name: students_student_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.students_student_id_seq', 354, true);


--
-- Name: subject_areas_area_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.subject_areas_area_id_seq', 12, true);


--
-- Name: subjects_subject_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.subjects_subject_id_seq', 56, true);


--
-- Name: teacher_subjects_teacher_subject_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.teacher_subjects_teacher_subject_id_seq', 135, true);


--
-- Name: terms_term_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.terms_term_id_seq', 1, false);


--
-- Name: timetable_assignments_assignment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.timetable_assignments_assignment_id_seq', 1, false);


--
-- Name: timetable_slots_slot_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.timetable_slots_slot_id_seq', 1, false);


--
-- Name: migrations PK_8c82d7f526340ab734260ea46be; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migrations
    ADD CONSTRAINT "PK_8c82d7f526340ab734260ea46be" PRIMARY KEY (id);


--
-- Name: attendance attendance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_pkey PRIMARY KEY (attendance_id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (audit_id);


--
-- Name: buildings buildings_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buildings
    ADD CONSTRAINT buildings_name_key UNIQUE (name);


--
-- Name: buildings buildings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.buildings
    ADD CONSTRAINT buildings_pkey PRIMARY KEY (building_id);


--
-- Name: class_group_curriculum_overrides class_group_curriculum_overrides_group_item_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_curriculum_overrides
    ADD CONSTRAINT class_group_curriculum_overrides_group_item_key UNIQUE (class_group_id, curriculum_item_id);


--
-- Name: class_group_curriculum_overrides class_group_curriculum_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_curriculum_overrides
    ADD CONSTRAINT class_group_curriculum_overrides_pkey PRIMARY KEY (override_id);


--
-- Name: class_group_fixed_locations class_group_fixed_locations_grade_section_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_fixed_locations
    ADD CONSTRAINT class_group_fixed_locations_grade_section_key UNIQUE (grade_level, section);


--
-- Name: class_group_fixed_locations class_group_fixed_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_fixed_locations
    ADD CONSTRAINT class_group_fixed_locations_pkey PRIMARY KEY (fixed_location_id);


--
-- Name: class_groups class_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_groups
    ADD CONSTRAINT class_groups_pkey PRIMARY KEY (class_group_id);


--
-- Name: class_groups class_groups_school_year_id_grade_level_section_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_groups
    ADD CONSTRAINT class_groups_school_year_id_grade_level_section_key UNIQUE (school_year_id, grade_level, section);


--
-- Name: classrooms classrooms_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.classrooms
    ADD CONSTRAINT classrooms_name_key UNIQUE (name);


--
-- Name: classrooms classrooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.classrooms
    ADD CONSTRAINT classrooms_pkey PRIMARY KEY (classroom_id);


--
-- Name: course_instances course_instances_course_code_school_year_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_instances
    ADD CONSTRAINT course_instances_course_code_school_year_id_key UNIQUE (course_code, school_year_id);


--
-- Name: course_instances course_instances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_instances
    ADD CONSTRAINT course_instances_pkey PRIMARY KEY (course_instance_id);


--
-- Name: courses courses_course_instance_id_class_group_id_teacher_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_course_instance_id_class_group_id_teacher_id_key UNIQUE (course_instance_id, class_group_id, teacher_id);


--
-- Name: courses courses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_pkey PRIMARY KEY (course_id);


--
-- Name: curricula curricula_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curricula
    ADD CONSTRAINT curricula_pkey PRIMARY KEY (curriculum_id);


--
-- Name: curriculum_items curriculum_items_curriculum_subject_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum_items
    ADD CONSTRAINT curriculum_items_curriculum_subject_key UNIQUE (curriculum_id, subject_id);


--
-- Name: curriculum_items curriculum_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum_items
    ADD CONSTRAINT curriculum_items_pkey PRIMARY KEY (curriculum_item_id);


--
-- Name: disciplinary_records disciplinary_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disciplinary_records
    ADD CONSTRAINT disciplinary_records_pkey PRIMARY KEY (disciplinary_id);


--
-- Name: enrollments enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_pkey PRIMARY KEY (enrollment_id);


--
-- Name: enrollments enrollments_student_id_class_group_id_school_year_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_student_id_class_group_id_school_year_id_key UNIQUE (student_id, class_group_id, school_year_id);


--
-- Name: grade_scheme_values grade_scheme_values_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_scheme_values
    ADD CONSTRAINT grade_scheme_values_pkey PRIMARY KEY (value_id);


--
-- Name: grade_scheme_values grade_scheme_values_scheme_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_scheme_values
    ADD CONSTRAINT grade_scheme_values_scheme_id_code_key UNIQUE (scheme_id, code);


--
-- Name: grade_schemes grade_schemes_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_schemes
    ADD CONSTRAINT grade_schemes_name_key UNIQUE (name);


--
-- Name: grade_schemes grade_schemes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_schemes
    ADD CONSTRAINT grade_schemes_pkey PRIMARY KEY (scheme_id);


--
-- Name: grades grades_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_pkey PRIMARY KEY (grade_id);


--
-- Name: grades grades_student_id_course_id_term_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_student_id_course_id_term_id_key UNIQUE (student_id, course_id, term_id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (notification_id);


--
-- Name: planilla_sheets planilla_sheets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.planilla_sheets
    ADD CONSTRAINT planilla_sheets_pkey PRIMARY KEY (planilla_sheet_id);


--
-- Name: school_years school_years_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.school_years
    ADD CONSTRAINT school_years_name_key UNIQUE (name);


--
-- Name: school_years school_years_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.school_years
    ADD CONSTRAINT school_years_pkey PRIMARY KEY (school_year_id);


--
-- Name: students students_national_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_national_id_key UNIQUE (national_id);


--
-- Name: students students_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.students
    ADD CONSTRAINT students_pkey PRIMARY KEY (student_id);


--
-- Name: subject_areas subject_areas_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subject_areas
    ADD CONSTRAINT subject_areas_code_key UNIQUE (code);


--
-- Name: subject_areas subject_areas_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subject_areas
    ADD CONSTRAINT subject_areas_name_key UNIQUE (name);


--
-- Name: subject_areas subject_areas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subject_areas
    ADD CONSTRAINT subject_areas_pkey PRIMARY KEY (area_id);


--
-- Name: subjects subjects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subjects
    ADD CONSTRAINT subjects_pkey PRIMARY KEY (subject_id);


--
-- Name: subjects subjects_subject_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subjects
    ADD CONSTRAINT subjects_subject_code_key UNIQUE (subject_code);


--
-- Name: teacher_subjects teacher_subjects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teacher_subjects
    ADD CONSTRAINT teacher_subjects_pkey PRIMARY KEY (teacher_subject_id);


--
-- Name: teacher_subjects teacher_subjects_teacher_subject_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teacher_subjects
    ADD CONSTRAINT teacher_subjects_teacher_subject_key UNIQUE (teacher_id, subject_id);


--
-- Name: terms terms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms
    ADD CONSTRAINT terms_pkey PRIMARY KEY (term_id);


--
-- Name: terms terms_school_year_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms
    ADD CONSTRAINT terms_school_year_id_name_key UNIQUE (school_year_id, name);


--
-- Name: timetable_assignments timetable_assignments_course_id_slot_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_assignments
    ADD CONSTRAINT timetable_assignments_course_id_slot_id_key UNIQUE (course_id, slot_id);


--
-- Name: timetable_assignments timetable_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_assignments
    ADD CONSTRAINT timetable_assignments_pkey PRIMARY KEY (assignment_id);


--
-- Name: timetable_slots timetable_slots_day_of_week_start_time_end_time_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_slots
    ADD CONSTRAINT timetable_slots_day_of_week_start_time_end_time_key UNIQUE (day_of_week, start_time, end_time);


--
-- Name: timetable_slots timetable_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_slots
    ADD CONSTRAINT timetable_slots_pkey PRIMARY KEY (slot_id);


--
-- Name: planilla_sheets uq_planilla_sheets_year_group_template; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.planilla_sheets
    ADD CONSTRAINT uq_planilla_sheets_year_group_template UNIQUE (school_year_id, group_code, template_key);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (national_id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: idx_attendance_course_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attendance_course_date ON public.attendance USING btree (course_id, date);


--
-- Name: idx_attendance_student_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attendance_student_date ON public.attendance USING btree (student_id, date);


--
-- Name: idx_class_group_fixed_locations_classroom_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_class_group_fixed_locations_classroom_id ON public.class_group_fixed_locations USING btree (classroom_id);


--
-- Name: idx_classrooms_building_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_classrooms_building_id ON public.classrooms USING btree (building_id);


--
-- Name: idx_enrollments_grade_year; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_grade_year ON public.enrollments USING btree (school_year_id, grade_level);


--
-- Name: idx_enrollments_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_pending ON public.enrollments USING btree (school_year_id, grade_level) WHERE (class_group_id IS NULL);


--
-- Name: idx_enrollments_student; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_student ON public.enrollments USING btree (student_id);


--
-- Name: idx_enrollments_year; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_year ON public.enrollments USING btree (school_year_id);


--
-- Name: idx_planilla_sheets_grade_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_planilla_sheets_grade_group ON public.planilla_sheets USING btree (grade_level, group_code);


--
-- Name: idx_planilla_sheets_import_closed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_planilla_sheets_import_closed_at ON public.planilla_sheets USING btree (import_closed_at);


--
-- Name: uniq_active_student_category; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_active_student_category ON public.notifications USING btree (student_id, category) WHERE ((is_active = true) AND (student_id IS NOT NULL));


--
-- Name: uniq_attendance_student_date_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_attendance_student_date_slot ON public.attendance USING btree (student_id, date, slot_id) WHERE (slot_id IS NOT NULL);


--
-- Name: uniq_cg_year_grade_section; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_cg_year_grade_section ON public.class_groups USING btree (school_year_id, grade_level, section);


--
-- Name: uniq_ci_coursecode_year; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_ci_coursecode_year ON public.course_instances USING btree (course_code, school_year_id);


--
-- Name: uniq_ci_subject_grade_year; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_ci_subject_grade_year ON public.course_instances USING btree (subject_id, grade_level, school_year_id);


--
-- Name: uniq_class_groups_year_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_class_groups_year_code ON public.class_groups USING btree (school_year_id, (((grade_level)::text || (section)::text)));


--
-- Name: uniq_classgroup_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_classgroup_slot ON public.timetable_assignments USING btree (class_group_id, slot_id) WHERE (class_group_id IS NOT NULL);


--
-- Name: uniq_course_ci_cg_teacher; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_course_ci_cg_teacher ON public.courses USING btree (course_instance_id, class_group_id, teacher_id);


--
-- Name: uniq_enrollment_student_year_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_enrollment_student_year_active ON public.enrollments USING btree (student_id, school_year_id) WHERE active;


--
-- Name: uniq_grade_student_course_term; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_grade_student_course_term ON public.grades USING btree (student_id, course_id, term_id);


--
-- Name: uniq_teacher_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_teacher_slot ON public.timetable_assignments USING btree (teacher_id, slot_id) WHERE (teacher_id IS NOT NULL);


--
-- Name: uniq_timetable_classroom_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_timetable_classroom_slot ON public.timetable_assignments USING btree (slot_id, classroom_id) WHERE (classroom_id IS NOT NULL);


--
-- Name: uniq_timetable_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_timetable_slot ON public.timetable_slots USING btree (day_of_week, start_time, end_time);


--
-- Name: ux_attendance_legacy_daily; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_attendance_legacy_daily ON public.attendance USING btree (student_id, course_id, date) WHERE (slot_id IS NULL);


--
-- Name: ux_attendance_per_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_attendance_per_slot ON public.attendance USING btree (student_id, course_id, date, slot_id) WHERE (slot_id IS NOT NULL);


--
-- Name: ux_course_instances_class_group_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_course_instances_class_group_scope ON public.course_instances USING btree (subject_id, class_group_id, school_year_id) WHERE (scope_type = 'CLASS_GROUP'::public.course_instance_scope);


--
-- Name: ux_course_instances_grade_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_course_instances_grade_scope ON public.course_instances USING btree (subject_id, grade_level, school_year_id) WHERE (scope_type = 'GRADE'::public.course_instance_scope);


--
-- Name: ux_curricula_grade_base; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_curricula_grade_base ON public.curricula USING btree (grade_level) WHERE (track_name IS NULL);


--
-- Name: ux_curricula_grade_track; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_curricula_grade_track ON public.curricula USING btree (grade_level, track_name) WHERE (track_name IS NOT NULL);


--
-- Name: attendance trg_attendance_excuse; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_attendance_excuse BEFORE UPDATE ON public.attendance FOR EACH ROW EXECUTE FUNCTION public.check_excuse_editor();


--
-- Name: attendance trg_attendance_slot_day; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_attendance_slot_day BEFORE INSERT OR UPDATE ON public.attendance FOR EACH ROW EXECUTE FUNCTION public.check_attendance_slot_day();


--
-- Name: courses trg_courses_grade_level; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_courses_grade_level BEFORE INSERT OR UPDATE ON public.courses FOR EACH ROW EXECUTE FUNCTION public.check_course_grade_level();


--
-- Name: grades trg_grades_enrollment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_grades_enrollment BEFORE INSERT OR UPDATE ON public.grades FOR EACH ROW EXECUTE FUNCTION public.check_grade_enrollment();


--
-- Name: timetable_assignments trg_room_conflict; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_room_conflict BEFORE INSERT OR UPDATE ON public.timetable_assignments FOR EACH ROW EXECUTE FUNCTION public.check_room_double_booking();


--
-- Name: timetable_assignments trg_ta_fill; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ta_fill BEFORE INSERT OR UPDATE ON public.timetable_assignments FOR EACH ROW EXECUTE FUNCTION public.fill_assignment_denorm();


--
-- Name: terms trg_term_in_year; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_term_in_year BEFORE INSERT OR UPDATE ON public.terms FOR EACH ROW EXECUTE FUNCTION public.check_term_in_year();


--
-- Name: attendance attendance_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(course_id) ON DELETE CASCADE;


--
-- Name: attendance attendance_course_slot_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_course_slot_fkey FOREIGN KEY (course_id, slot_id) REFERENCES public.timetable_assignments(course_id, slot_id);


--
-- Name: attendance attendance_excused_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_excused_by_fkey FOREIGN KEY (excused_by) REFERENCES public.users(national_id);


--
-- Name: attendance attendance_recorded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES public.users(national_id);


--
-- Name: attendance attendance_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(student_id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_performed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.users(national_id);


--
-- Name: class_group_curriculum_overrides class_group_curriculum_overrides_class_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_curriculum_overrides
    ADD CONSTRAINT class_group_curriculum_overrides_class_group_id_fkey FOREIGN KEY (class_group_id) REFERENCES public.class_groups(class_group_id) ON DELETE CASCADE;


--
-- Name: class_group_curriculum_overrides class_group_curriculum_overrides_curriculum_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_curriculum_overrides
    ADD CONSTRAINT class_group_curriculum_overrides_curriculum_item_id_fkey FOREIGN KEY (curriculum_item_id) REFERENCES public.curriculum_items(curriculum_item_id) ON DELETE CASCADE;


--
-- Name: class_group_fixed_locations class_group_fixed_locations_classroom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_group_fixed_locations
    ADD CONSTRAINT class_group_fixed_locations_classroom_id_fkey FOREIGN KEY (classroom_id) REFERENCES public.classrooms(classroom_id) ON DELETE RESTRICT;


--
-- Name: class_groups class_groups_classroom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_groups
    ADD CONSTRAINT class_groups_classroom_id_fkey FOREIGN KEY (classroom_id) REFERENCES public.classrooms(classroom_id);


--
-- Name: class_groups class_groups_school_year_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.class_groups
    ADD CONSTRAINT class_groups_school_year_id_fkey FOREIGN KEY (school_year_id) REFERENCES public.school_years(school_year_id) ON DELETE CASCADE;


--
-- Name: classrooms classrooms_building_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.classrooms
    ADD CONSTRAINT classrooms_building_id_fkey FOREIGN KEY (building_id) REFERENCES public.buildings(building_id) ON DELETE RESTRICT;


--
-- Name: course_instances course_instances_class_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_instances
    ADD CONSTRAINT course_instances_class_group_id_fkey FOREIGN KEY (class_group_id) REFERENCES public.class_groups(class_group_id) ON DELETE CASCADE;


--
-- Name: course_instances course_instances_curriculum_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_instances
    ADD CONSTRAINT course_instances_curriculum_item_id_fkey FOREIGN KEY (curriculum_item_id) REFERENCES public.curriculum_items(curriculum_item_id) ON DELETE SET NULL;


--
-- Name: course_instances course_instances_school_year_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_instances
    ADD CONSTRAINT course_instances_school_year_id_fkey FOREIGN KEY (school_year_id) REFERENCES public.school_years(school_year_id) ON DELETE CASCADE;


--
-- Name: course_instances course_instances_subject_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_instances
    ADD CONSTRAINT course_instances_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES public.subjects(subject_id) ON DELETE RESTRICT;


--
-- Name: courses courses_class_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_class_group_id_fkey FOREIGN KEY (class_group_id) REFERENCES public.class_groups(class_group_id) ON DELETE CASCADE;


--
-- Name: courses courses_course_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_course_instance_id_fkey FOREIGN KEY (course_instance_id) REFERENCES public.course_instances(course_instance_id) ON DELETE CASCADE;


--
-- Name: courses courses_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.users(national_id) ON DELETE RESTRICT;


--
-- Name: curriculum_items curriculum_items_curriculum_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum_items
    ADD CONSTRAINT curriculum_items_curriculum_id_fkey FOREIGN KEY (curriculum_id) REFERENCES public.curricula(curriculum_id) ON DELETE CASCADE;


--
-- Name: curriculum_items curriculum_items_subject_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curriculum_items
    ADD CONSTRAINT curriculum_items_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES public.subjects(subject_id) ON DELETE CASCADE;


--
-- Name: disciplinary_records disciplinary_records_recorded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disciplinary_records
    ADD CONSTRAINT disciplinary_records_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES public.users(national_id);


--
-- Name: disciplinary_records disciplinary_records_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.disciplinary_records
    ADD CONSTRAINT disciplinary_records_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(student_id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_class_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_class_group_id_fkey FOREIGN KEY (class_group_id) REFERENCES public.class_groups(class_group_id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_school_year_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_school_year_id_fkey FOREIGN KEY (school_year_id) REFERENCES public.school_years(school_year_id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(student_id) ON DELETE CASCADE;


--
-- Name: curricula fk_curricula_specialization_area; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.curricula
    ADD CONSTRAINT fk_curricula_specialization_area FOREIGN KEY (specialization_area_id) REFERENCES public.subject_areas(area_id) ON DELETE RESTRICT;


--
-- Name: notifications fk_notifications_student; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT fk_notifications_student FOREIGN KEY (student_id) REFERENCES public.students(student_id) ON DELETE SET NULL;


--
-- Name: planilla_sheets fk_planilla_sheets_class_group; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.planilla_sheets
    ADD CONSTRAINT fk_planilla_sheets_class_group FOREIGN KEY (class_group_id) REFERENCES public.class_groups(class_group_id) ON DELETE SET NULL;


--
-- Name: planilla_sheets fk_planilla_sheets_imported_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.planilla_sheets
    ADD CONSTRAINT fk_planilla_sheets_imported_by FOREIGN KEY (imported_by) REFERENCES public.users(national_id) ON DELETE SET NULL;


--
-- Name: planilla_sheets fk_planilla_sheets_school_year; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.planilla_sheets
    ADD CONSTRAINT fk_planilla_sheets_school_year FOREIGN KEY (school_year_id) REFERENCES public.school_years(school_year_id) ON DELETE CASCADE;


--
-- Name: grade_scheme_values grade_scheme_values_scheme_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grade_scheme_values
    ADD CONSTRAINT grade_scheme_values_scheme_id_fkey FOREIGN KEY (scheme_id) REFERENCES public.grade_schemes(scheme_id) ON DELETE CASCADE;


--
-- Name: grades grades_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(course_id) ON DELETE CASCADE;


--
-- Name: grades grades_recorded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES public.users(national_id);


--
-- Name: grades grades_scheme_value_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_scheme_value_id_fkey FOREIGN KEY (scheme_value_id) REFERENCES public.grade_scheme_values(value_id) ON DELETE RESTRICT;


--
-- Name: grades grades_student_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(student_id) ON DELETE CASCADE;


--
-- Name: grades grades_term_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.grades
    ADD CONSTRAINT grades_term_id_fkey FOREIGN KEY (term_id) REFERENCES public.terms(term_id) ON DELETE CASCADE;


--
-- Name: notifications notifications_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(national_id);


--
-- Name: subjects subjects_area_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subjects
    ADD CONSTRAINT subjects_area_id_fkey FOREIGN KEY (area_id) REFERENCES public.subject_areas(area_id) ON DELETE RESTRICT;


--
-- Name: teacher_subjects teacher_subjects_subject_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teacher_subjects
    ADD CONSTRAINT teacher_subjects_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES public.subjects(subject_id) ON DELETE RESTRICT;


--
-- Name: teacher_subjects teacher_subjects_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teacher_subjects
    ADD CONSTRAINT teacher_subjects_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.users(national_id) ON DELETE CASCADE;


--
-- Name: terms terms_school_year_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms
    ADD CONSTRAINT terms_school_year_id_fkey FOREIGN KEY (school_year_id) REFERENCES public.school_years(school_year_id) ON DELETE CASCADE;


--
-- Name: timetable_assignments timetable_assignments_classroom_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_assignments
    ADD CONSTRAINT timetable_assignments_classroom_id_fkey FOREIGN KEY (classroom_id) REFERENCES public.classrooms(classroom_id);


--
-- Name: timetable_assignments timetable_assignments_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_assignments
    ADD CONSTRAINT timetable_assignments_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(course_id) ON DELETE CASCADE;


--
-- Name: timetable_assignments timetable_assignments_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.timetable_assignments
    ADD CONSTRAINT timetable_assignments_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES public.timetable_slots(slot_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--
