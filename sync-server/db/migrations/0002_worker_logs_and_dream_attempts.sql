CREATE TABLE public.worker_dream_attempts (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    record_id uuid NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT worker_dream_attempts_pkey PRIMARY KEY (user_id, device_id, record_id),
    CONSTRAINT worker_dream_attempts_attempts_check CHECK (attempts > 0),
    CONSTRAINT worker_dream_attempts_user_device_fkey
      FOREIGN KEY (user_id, device_id)
      REFERENCES public.devices(user_id, id) ON DELETE CASCADE,
    CONSTRAINT worker_dream_attempts_user_record_fkey
      FOREIGN KEY (user_id, record_id)
      REFERENCES public.records(user_id, id) ON DELETE CASCADE
);

CREATE TABLE public.worker_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    level text NOT NULL,
    message text NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT worker_logs_pkey PRIMARY KEY (id),
    CONSTRAINT worker_logs_user_device_fkey
      FOREIGN KEY (user_id, device_id)
      REFERENCES public.devices(user_id, id) ON DELETE CASCADE,
    CONSTRAINT worker_logs_context_check CHECK (jsonb_typeof(context) = 'object'),
    CONSTRAINT worker_logs_context_size_check
      CHECK (public.exeligmos_jsonb_compact_octet_length(context) <= 32768),
    CONSTRAINT worker_logs_level_check
      CHECK (level IN ('debug', 'info', 'warn', 'error')),
    CONSTRAINT worker_logs_message_check
      CHECK (
        message = btrim(message)
        AND char_length(message) BETWEEN 1 AND 4000
      )
);

CREATE INDEX worker_logs_user_device_created_idx
ON public.worker_logs (user_id, device_id, created_at DESC, id DESC);
