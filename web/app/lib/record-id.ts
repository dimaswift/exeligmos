const RECORD_PUBLIC_ID = /^[A-Za-z0-9_-]{5}$/;

export function isRecordPublicId(value: string | undefined): value is string {
  return value !== undefined && RECORD_PUBLIC_ID.test(value);
}
