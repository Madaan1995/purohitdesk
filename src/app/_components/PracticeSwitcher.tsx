'use client';

import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';

/** Picks the practice sent as X-Tenant-ID / read by pages. The database re-checks membership on every request. */
export function PracticeSwitcher({ current, practices }: { current: string; practices: { id: string; name: string }[] }) {
  const t = useTranslations('nav');
  const router = useRouter();
  return (
    <label className="flex flex-col gap-1 text-base">
      <span>{t('switchPractice')}</span>
      <select
        value={current}
        onChange={(e) => {
          document.cookie = `pd_tenant=${e.target.value}; path=/; max-age=31536000; samesite=lax`;
          router.refresh();
        }}
        className="min-h-11 rounded-lg border border-neutral-300 bg-white px-3 text-base"
      >
        {practices.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
          </option>
        ))}
      </select>
    </label>
  );
}
