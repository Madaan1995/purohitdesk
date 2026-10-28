export function FormStatus({ error, saved }: { error: string | null; saved: string | null }) {
  if (error) {
    return (
      <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-base text-red-800">
        {error}
      </p>
    );
  }
  if (saved) {
    return (
      <p role="status" className="rounded-lg bg-green-50 px-3 py-2 text-base text-green-800">
        {saved}
      </p>
    );
  }
  return null;
}
