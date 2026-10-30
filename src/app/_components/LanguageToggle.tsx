'use client';

import { useLocale, useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { useState } from 'react';

/** हिन्दी ⇄ English. Signed in: saved to the profile (PATCH /api/v1/me sets the cookie). Signed out: cookie only. */
export function LanguageToggle({ signedIn }: { signedIn: boolean }) {
  const t = useTranslations('nav');
  const locale = useLocale();
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const next = locale === 'hi' ? 'en' : 'hi';

  async function toggle() {
    setBusy(true);
    try {
      if (signedIn) {
        await fetch('/api/v1/me', {
          method: 'PATCH',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ preferred_locale: next }),
        });
      } else {
        document.cookie = `NEXT_LOCALE=${next}; path=/; max-age=31536000; samesite=lax`;
      }
      router.refresh();
    } finally {
      setBusy(false);
    }
  }

  return (
    <button
      type="button"
      onClick={toggle}
      disabled={busy}
      lang={next}
      className="min-h-11 rounded-lg border border-neutral-300 px-4 text-base disabled:opacity-60"
    >
      {t('switchLanguage')}
    </button>
  );
}
