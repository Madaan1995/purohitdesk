import Link from "next/link";

export const CONTACT_EMAIL = "amanmadaan87@gmail.com";

// Public placeholder notice for the staging app: Hindi first, then the same text in English.
export function LegalPage({
  hindi,
  english,
}: {
  hindi: { title: string; body: React.ReactNode };
  english: { title: string; body: React.ReactNode };
}) {
  return (
    <main className="mx-auto flex max-w-2xl flex-col gap-8 px-4 py-6 text-base">
      <Link href="/" className="flex min-h-11 items-center text-brand underline">
        ← पुरोहित डेस्क · <span lang="en">PurohitDesk</span>
      </Link>
      <section className="flex flex-col gap-3">
        <h1 className="text-2xl font-bold">{hindi.title}</h1>
        {hindi.body}
      </section>
      <section lang="en" className="flex flex-col gap-3 border-t border-neutral-200 pt-6">
        <h1 className="text-2xl font-bold">{english.title}</h1>
        {english.body}
      </section>
    </main>
  );
}

export function ContactLink() {
  return (
    <a href={`mailto:${CONTACT_EMAIL}`} className="text-brand underline">
      {CONTACT_EMAIL}
    </a>
  );
}
